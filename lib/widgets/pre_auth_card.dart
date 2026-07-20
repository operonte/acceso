import 'package:flutter/material.dart';
import '../models/pre_auth_record.dart';
import '../screens/login_screen.dart' show UserRole;
import '../theme/colors.dart';

class PreAuthCard extends StatelessWidget {
  final PreAuthRecord pre;
  final UserRole userRole;
  final VoidCallback onShowQRPass;
  final VoidCallback onCheckin;

  const PreAuthCard({
    super.key,
    required this.pre,
    required this.userRole,
    required this.onShowQRPass,
    required this.onCheckin,
  });

  @override
  Widget build(BuildContext context) {
    final isVehicle = pre.type == 'vehiculo';
    final cardAccentColor = isVehicle ? const Color(0xFF3B82F6) : const Color(0xFF10B981);
    final visitDateStr = '${pre.visitDate.day}/${pre.visitDate.month}/${pre.visitDate.year}';
    
    // Check if it's today's visit
    final bool isToday = pre.visitDate.year == DateTime.now().year &&
        pre.visitDate.month == DateTime.now().month &&
        pre.visitDate.day == DateTime.now().day;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isToday ? Colors.amber.withValues(alpha: 0.2) : Colors.transparent,
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
                color: isToday ? Colors.amber : cardAccentColor.withValues(alpha: 0.6),
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
                            isVehicle ? 'VEHÍCULO AUTORIZADO' : 'PERSONA AUTORIZADA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: cardAccentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isToday ? Colors.amber.withValues(alpha: 0.2) : slate900,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              isToday ? 'HOY' : visitDateStr,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isToday ? Colors.amber : slate300,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        pre.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI: ${pre.docId}',
                        style: const TextStyle(fontSize: 12, color: slate400),
                      ),
                      const SizedBox(height: 6),

                      if (isVehicle && pre.plate != null) ...[
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
                                pre.plate!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orangeAccent,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                pre.vehicleType ?? '',
                                style: const TextStyle(fontSize: 11, color: slate400),
                              )
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],

                      Row(
                        children: [
                          const Icon(Icons.meeting_room, size: 14, color: Colors.amber),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Destino: ${pre.destination}',
                              style: const TextStyle(fontSize: 13, color: slate300),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Button to view QR Pass
              InkWell(
                onTap: onShowQRPass,
                child: Container(
                  width: 75,
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: slate700, width: 1),
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_2_rounded, color: Colors.amber, size: 24),
                      SizedBox(height: 4),
                      Text(
                        'Ver QR',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Button to authorize entry (Mark In)
              if (userRole != UserRole.cliente)
                InkWell(
                  onTap: onCheckin,
                  child: Container(
                    width: 75,
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                      border: const Border(
                        left: BorderSide(color: slate700, width: 1),
                      ),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.login_rounded, color: Color(0xFF10B981), size: 24),
                        SizedBox(height: 4),
                        Text(
                          'Ingreso',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
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
