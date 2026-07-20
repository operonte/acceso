import 'package:flutter/material.dart';
import '../theme/colors.dart';

class DashboardStats extends StatelessWidget {
  final int peopleInsideCount;
  final int vehiclesInsideCount;
  final int trucksInsideCount;
  final int motosInsideCount;
  final int bikesInsideCount;

  const DashboardStats({
    super.key,
    required this.peopleInsideCount,
    required this.vehiclesInsideCount,
    this.trucksInsideCount = 0,
    this.motosInsideCount = 0,
    this.bikesInsideCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                title: 'Personas Dentro',
                value: '$peopleInsideCount',
                icon: Icons.people_alt_rounded,
                color: const Color(0xFF10B981),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                title: 'Vehículos Dentro',
                value: '$vehiclesInsideCount',
                icon: Icons.directions_car_rounded,
                color: const Color(0xFF3B82F6),
              ),
            ),
          ],
        ),
        if (trucksInsideCount > 0 || motosInsideCount > 0 || bikesInsideCount > 0) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (trucksInsideCount > 0)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: (motosInsideCount > 0 || bikesInsideCount > 0) ? 12 : 0,
                    ),
                    child: _StatCard(
                      title: 'Camiones Dentro',
                      value: '$trucksInsideCount',
                      icon: Icons.local_shipping_rounded,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              if (motosInsideCount > 0)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: bikesInsideCount > 0 ? 12 : 0,
                    ),
                    child: _StatCard(
                      title: 'Motos Dentro',
                      value: '$motosInsideCount',
                      icon: Icons.motorcycle_rounded,
                      color: Colors.deepPurpleAccent,
                    ),
                  ),
                ),
              if (bikesInsideCount > 0)
                Expanded(
                  child: _StatCard(
                    title: 'Bicicletas Dentro',
                    value: '$bikesInsideCount',
                    icon: Icons.pedal_bike_rounded,
                    color: Colors.tealAccent,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: slate900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
                ),
                Text(
                  title,
                  style: const TextStyle(fontSize: 12, color: slate400),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
