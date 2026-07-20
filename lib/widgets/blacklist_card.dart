import 'package:flutter/material.dart';
import '../models/blacklist_entry.dart';
import '../theme/colors.dart';

class BlacklistCard extends StatelessWidget {
  final BlacklistEntry entry;
  final VoidCallback onRemove;

  const BlacklistCard({
    super.key,
    required this.entry,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isVehicle = entry.type == 'vehiculo';
    const accentColor = Colors.redAccent;
    final dateStr = '${entry.createdAt.day}/${entry.createdAt.month}/${entry.createdAt.year}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.2),
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
                color: accentColor,
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
                            color: accentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isVehicle ? 'VEHÍCULO BLOQUEADO' : 'PERSONA BLOQUEADA',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            dateStr,
                            style: const TextStyle(fontSize: 11, color: slate400),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        entry.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI/Patente: ${entry.identifier}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.report_gmailerrorred_rounded, size: 16, color: Colors.redAccent),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              entry.reason,
                              style: const TextStyle(fontSize: 13, color: slate300),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Button to delete (remove restriction)
              InkWell(
                onTap: onRemove,
                child: Container(
                  width: 70,
                  color: Colors.redAccent.withValues(alpha: 0.05),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 24),
                      SizedBox(height: 4),
                      Text(
                        'Eliminar',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.redAccent,
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
}
