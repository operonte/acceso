class BlacklistEntry {
  final String id;
  final String type; // 'persona' or 'vehiculo'
  final String name; // Name of person or driver
  final String identifier; // Cleaned RUT / DNI or License Plate
  final String reason; // Reason for restriction
  final DateTime createdAt;

  BlacklistEntry({
    required this.id,
    required this.type,
    required this.name,
    required this.identifier,
    required this.reason,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'name': name,
      'identifier': identifier,
      'reason': reason,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory BlacklistEntry.fromMap(Map<dynamic, dynamic> map) {
    return BlacklistEntry(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      identifier: map['identifier'] as String,
      reason: map['reason'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }
}
