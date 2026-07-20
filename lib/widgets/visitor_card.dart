import 'dart:io';
import 'package:flutter/material.dart';
import '../models/access_record.dart';
import '../screens/login_screen.dart' show UserRole;
import '../theme/colors.dart';

class VisitorCard extends StatelessWidget {
  final AccessRecord record;
  final UserRole userRole;
  final VoidCallback onCheckout;
  final VoidCallback onShowPhoto;

  const VisitorCard({
    super.key,
    required this.record,
    required this.userRole,
    required this.onCheckout,
    required this.onShowPhoto,
  });

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatDuration(DateTime start) {
    final diff = DateTime.now().difference(start);
    if (diff.inMinutes < 60) {
      return 'Hace ${diff.inMinutes}m';
    } else {
      final hours = diff.inHours;
      final mins = diff.inMinutes % 60;
      return 'Hace ${hours}h ${mins}m';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVehicle = record.type == 'vehiculo';
    final cardAccentColor = isVehicle ? const Color(0xFF3B82F6) : const Color(0xFF10B981);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: record.isInside ? cardAccentColor.withValues(alpha: 0.2) : Colors.transparent,
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 6,
                color: record.isInside ? cardAccentColor : slate600,
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isVehicle ? Icons.directions_car_rounded : Icons.person_rounded,
                            size: 16,
                            color: cardAccentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isVehicle ? 'VEHÍCULO' : 'PERSONA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: cardAccentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            record.isInside ? _formatDuration(record.entryTime) : 'Salida registrada',
                            style: TextStyle(
                              fontSize: 11,
                              color: record.isInside ? const Color(0xFF10B981) : slate400,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        record.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI: ${record.docId}',
                        style: const TextStyle(fontSize: 12, color: slate400),
                      ),
                      const SizedBox(height: 6),

                      if (isVehicle && record.plate != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: slate900,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: slate800),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.tag, size: 12, color: Colors.orangeAccent),
                              const SizedBox(width: 4),
                              Text(
                                record.plate!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orangeAccent,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                record.vehicleType ?? '',
                                style: const TextStyle(fontSize: 11, color: slate400),
                              )
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],

                      Row(
                        children: [
                          const Icon(Icons.location_on, size: 14, color: Colors.redAccent),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              record.destination,
                              style: const TextStyle(fontSize: 13, color: slate300),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Row(
                        children: [
                          const Icon(Icons.login, size: 12, color: slate400),
                          const SizedBox(width: 4),
                          Text(
                            'Ingreso: ${_formatTime(record.entryTime)}',
                            style: const TextStyle(fontSize: 11, color: slate400),
                          ),
                          if (record.exitTime != null) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.logout, size: 12, color: slate400),
                            const SizedBox(width: 4),
                            Text(
                              'Salida: ${_formatTime(record.exitTime!)}',
                              style: const TextStyle(fontSize: 11, color: slate400),
                            ),
                          ]
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              if (record.photoPath != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: InkWell(
                      onTap: onShowShowPhoto,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: record.photoPath!.startsWith('http')
                            ? Image.network(
                                record.photoPath!,
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: slate400, size: 20),
                              )
                            : Image.file(
                                File(record.photoPath!),
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: slate400, size: 20),
                              ),
                      ),
                    ),
                  ),
                ),

              if (record.isInside && userRole != UserRole.cliente)
                InkWell(
                  onTap: onCheckout,
                  child: Container(
                    width: 70,
                    color: Colors.blueAccent.withValues(alpha: 0.1),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.logout_rounded, color: Colors.blueAccent, size: 24),
                        SizedBox(height: 4),
                        Text(
                          'Salida',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper method so we don't break existing callback names if needed
  VoidCallback get onShowShowPhoto => onShowPhoto;
}
