import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../models/pre_auth_record.dart';
import '../models/blacklist_entry.dart';
import '../utils/supabase_sync_manager.dart';
import '../theme/colors.dart';

class CsvImportModal {
  /// Date parser for various format options
  static DateTime _parseImportDate(dynamic val, DateTime defaultDate) {
    if (val == null || val.toString().trim().isEmpty) return defaultDate;
    final clean = val.toString().trim();
    try {
      return DateTime.parse(clean);
    } catch (_) {
      try {
        final parts = clean.split('/');
        if (parts.length == 3) {
          return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        }
      } catch (_) {}
      try {
        final parts = clean.split('-');
        if (parts.length == 3) {
          if (parts[0].length == 4) {
            return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
          } else {
            return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
          }
        }
      } catch (_) {}
      return defaultDate;
    }
  }

  /// Opens the Pre-Authorization CSV Import dialog instructions
  static Future<void> importPreAuths(
    BuildContext context, {
    required VoidCallback onImportSuccess,
    required Function({required String type, required String title, required String body}) addNotification,
  }) async {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: slate800,
          title: const Row(
            children: [
              Icon(Icons.upload_file_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Text('Importar Pre-Autorizaciones', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'El archivo CSV debe contener las siguientes columnas:',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                '1. Tipo (persona / vehiculo)\n'
                '2. Nombre Completo\n'
                '3. Documento / RUT / ID\n'
                '4. Patente / Placa (opcional)\n'
                '5. Tipo Vehículo (opcional)\n'
                '6. Destino / Unidad / Dpto\n'
                '7. Fecha Inicio (AAAA-MM-DD)\n'
                '8. Fecha Fin (AAAA-MM-DD)',
                style: TextStyle(color: slate400, fontSize: 12, height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                'Soporta delimitadores de coma (,) y punto y coma (;).',
                style: TextStyle(color: Colors.amber, fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade700, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(dialogCtx);
                _pickAndParsePreAuthsCSV(context, onImportSuccess: onImportSuccess, addNotification: addNotification);
              },
              child: const Text('Seleccionar Archivo'),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _pickAndParsePreAuthsCSV(
    BuildContext context, {
    required VoidCallback onImportSuccess,
    required Function({required String type, required String title, required String body}) addNotification,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      String csvString;
      try {
        final bytes = await File(path).readAsBytes();
        csvString = utf8.decode(bytes);
      } catch (_) {
        final bytes = await File(path).readAsBytes();
        csvString = latin1.decode(bytes);
      }

      // Auto-detect delimiter
      String delimiter = ',';
      if (csvString.contains(';')) {
        final commaCount = ','.allMatches(csvString).length;
        final semiCount = ';'.allMatches(csvString).length;
        if (semiCount > commaCount) {
          delimiter = ';';
        }
      }

      // Normalize line endings
      csvString = csvString.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      final converter = CsvDecoder(fieldDelimiter: delimiter);
      final List<List<dynamic>> rows = converter.convert(csvString);

      if (rows.isEmpty) {
        throw Exception('El archivo seleccionado está vacío.');
      }

      // Check header
      int startIndex = 0;
      final firstRowJoin = rows[0].join().toLowerCase();
      if (firstRowJoin.contains('nombre') || firstRowJoin.contains('documento') || firstRowJoin.contains('tipo') || firstRowJoin.contains('rut')) {
        startIndex = 1;
      }

      final List<PreAuthRecord> parsedList = [];
      for (int i = startIndex; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 3) continue;

        final typeStr = row[0].toString().trim().toLowerCase();
        final type = (typeStr == 'vehiculo' || typeStr == 'vehículo') ? 'vehiculo' : 'persona';
        final name = row[1].toString().trim();
        final docId = row[2].toString().trim();
        
        if (name.isEmpty || docId.isEmpty) continue;

        final plate = row.length > 3 ? row[3].toString().trim() : '';
        final vehicleType = row.length > 4 ? row[4].toString().trim() : '';
        final destination = row.length > 5 ? row[5].toString().trim() : 'General';
        
        final toDate = row.length > 7 
            ? _parseImportDate(row[7], DateTime.now().add(const Duration(days: 365))) 
            : DateTime.now().add(const Duration(days: 365));

        parsedList.add(
          PreAuthRecord(
            id: 'pre_${DateTime.now().millisecondsSinceEpoch}_$i',
            type: type,
            name: name,
            docId: docId,
            plate: plate,
            vehicleType: vehicleType,
            destination: destination,
            visitDate: toDate,
            isUsed: false,
          ),
        );
      }

      if (parsedList.isEmpty) {
        throw Exception('No se encontraron registros válidos para importar.');
      }

      if (context.mounted) {
        _showPreAuthImportPreview(context, parsedList, onImportSuccess: onImportSuccess, addNotification: addNotification);
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al importar: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  static void _showPreAuthImportPreview(
    BuildContext context,
    List<PreAuthRecord> records, {
    required VoidCallback onImportSuccess,
    required Function({required String type, required String title, required String body}) addNotification,
  }) {
    showDialog(
      context: context,
      builder: (previewCtx) {
        return AlertDialog(
          backgroundColor: slate800,
          title: Text('Previsualizar Importación (${records.length})', style: const TextStyle(color: Colors.white, fontSize: 18)),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.4,
            child: ListView.separated(
              itemCount: records.length,
              separatorBuilder: (context, index) => const Divider(color: slate700),
              itemBuilder: (context, index) {
                final rec = records[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: rec.type == 'persona' ? Colors.blue.withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
                    child: Icon(rec.type == 'persona' ? Icons.person : Icons.directions_car, color: rec.type == 'persona' ? Colors.blue : Colors.green),
                  ),
                  title: Text(rec.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text(
                    'Doc: ${rec.docId} | Destino: ${rec.destination}\nFecha Autorizada: ${rec.visitDate.day}/${rec.visitDate.month}/${rec.visitDate.year}',
                    style: const TextStyle(color: slate400, fontSize: 11),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(previewCtx),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(previewCtx);
                final preAuthBox = Hive.box('pre_auth_box');
                for (var rec in records) {
                  await preAuthBox.put(rec.id, rec.toMap());
                }
                onImportSuccess();
                addNotification(
                  type: 'sync',
                  title: 'Importación Exitosa',
                  body: 'Se importaron ${records.length} pre-autorizaciones desde CSV.',
                );
                SupabaseSyncManager.syncAll();
              },
              child: const Text('Confirmar e Importar'),
            ),
          ],
        );
      },
    );
  }

  /// Opens the Blacklist CSV Import dialog instructions
  static Future<void> importBlacklist(
    BuildContext context, {
    required VoidCallback onImportSuccess,
    required Function({required String type, required String title, required String body}) addNotification,
  }) async {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: slate800,
          title: const Row(
            children: [
              Icon(Icons.upload_file_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Importar Lista Negra', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'El archivo CSV debe contener las siguientes columnas:',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                '1. Tipo (persona / vehiculo)\n'
                '2. Nombre Completo / Descripción\n'
                '3. Identificador (RUT / Placa / Patente)\n'
                '4. Motivo / Razón de Restricción',
                style: TextStyle(color: slate400, fontSize: 12, height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                'Soporta delimitadores de coma (,) y punto y coma (;).',
                style: TextStyle(color: Colors.redAccent, fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(dialogCtx);
                _pickAndParseBlacklistCSV(context, onImportSuccess: onImportSuccess, addNotification: addNotification);
              },
              child: const Text('Seleccionar Archivo'),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _pickAndParseBlacklistCSV(
    BuildContext context, {
    required VoidCallback onImportSuccess,
    required Function({required String type, required String title, required String body}) addNotification,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      String csvString;
      try {
        final bytes = await File(path).readAsBytes();
        csvString = utf8.decode(bytes);
      } catch (_) {
        final bytes = await File(path).readAsBytes();
        csvString = latin1.decode(bytes);
      }

      // Auto-detect delimiter
      String delimiter = ',';
      if (csvString.contains(';')) {
        final commaCount = ','.allMatches(csvString).length;
        final semiCount = ';'.allMatches(csvString).length;
        if (semiCount > commaCount) {
          delimiter = ';';
        }
      }

      // Normalize line endings
      csvString = csvString.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      final converter = CsvDecoder(fieldDelimiter: delimiter);
      final List<List<dynamic>> rows = converter.convert(csvString);

      if (rows.isEmpty) {
        throw Exception('El archivo seleccionado está vacío.');
      }

      // Check header
      int startIndex = 0;
      final firstRowJoin = rows[0].join().toLowerCase();
      if (firstRowJoin.contains('nombre') || firstRowJoin.contains('identificador') || firstRowJoin.contains('tipo') || firstRowJoin.contains('motivo')) {
        startIndex = 1;
      }

      final List<BlacklistEntry> parsedList = [];
      for (int i = startIndex; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 3) continue;

        final typeStr = row[0].toString().trim().toLowerCase();
        final type = (typeStr == 'vehiculo' || typeStr == 'vehículo') ? 'vehiculo' : 'persona';
        final name = row[1].toString().trim();
        final identifier = row[2].toString().trim();
        final reason = row.length > 3 ? row[3].toString().trim() : 'Sin motivo especificado';

        if (name.isEmpty || identifier.isEmpty) continue;

        parsedList.add(
          BlacklistEntry(
            id: 'bl_${DateTime.now().millisecondsSinceEpoch}_$i',
            type: type,
            name: name,
            identifier: identifier,
            reason: reason,
            createdAt: DateTime.now(),
          ),
        );
      }

      if (parsedList.isEmpty) {
        throw Exception('No se encontraron registros válidos de lista negra.');
      }

      if (context.mounted) {
        _showBlacklistImportPreview(context, parsedList, onImportSuccess: onImportSuccess, addNotification: addNotification);
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al importar: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  static void _showBlacklistImportPreview(
    BuildContext context,
    List<BlacklistEntry> entries, {
    required VoidCallback onImportSuccess,
    required Function({required String type, required String title, required String body}) addNotification,
  }) {
    showDialog(
      context: context,
      builder: (previewCtx) {
        return AlertDialog(
          backgroundColor: slate800,
          title: Text('Previsualizar Importación (${entries.length})', style: const TextStyle(color: Colors.white, fontSize: 18)),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.4,
            child: ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (context, index) => const Divider(color: slate700),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.withValues(alpha: 0.15),
                    child: Icon(entry.type == 'persona' ? Icons.person : Icons.directions_car, color: Colors.red),
                  ),
                  title: Text(entry.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text(
                    'Identificador: ${entry.identifier}\nMotivo: ${entry.reason}',
                    style: const TextStyle(color: slate400, fontSize: 11),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(previewCtx),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(previewCtx);
                final blacklistBox = Hive.box('blacklist_box');
                for (var entry in entries) {
                  await blacklistBox.put(entry.id, entry.toMap());
                }
                onImportSuccess();
                addNotification(
                  type: 'alerta',
                  title: 'Importación de Lista Negra',
                  body: 'Se importaron ${entries.length} registros a la Lista Negra.',
                );
                SupabaseSyncManager.syncAll();
              },
              child: const Text('Confirmar e Importar'),
            ),
          ],
        );
      },
    );
  }
}
