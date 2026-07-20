import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Fetch Access Records Data', () async {
    final client = SupabaseClient(
      'https://uajfwuwgbnpptvkujvwp.supabase.co',
      'sb_publishable__k-MtHWCMbpsCzek22ZVuQ_OOmr3P8j',
    );
    
    try {
      final res = await client.from('access_records').select().order('entry_time', ascending: false).limit(5);
      print('\n=== ÚLTIMOS INGRESOS (Supabase) ===\n');
      if (res.isNotEmpty) {
        for (var record in res) {
          print('Nombre: ${record['name']}');
          print('RUT: ${record['doc_id']}');
          print('Patente: ${record['plate'] ?? 'N/A'}');
          print('Tipo: ${record['type']}');
          print('Destino: ${record['destination']}');
          print('Fecha de Ingreso: ${record['entry_time']}');
          print('-----------------------------------');
        }
      } else {
        print('No hay registros de ingreso en la base de datos.');
      }
    } catch (e) {
      print('Error querying access_records: $e');
    }
  });
}
