class WhitelistEntry {
  final String id;
  final String type; // 'persona' or 'vehiculo'
  final String name; // Name of person or driver/owner
  final String identifier; // Cleaned RUT / DNI or License Plate
  final String unitOrRole; // e.g. 'Depto 402', 'Residente', 'Personal'
  final DateTime createdAt;

  WhitelistEntry({
    required this.id,
    required this.type,
    required this.name,
    required this.identifier,
    required this.unitOrRole,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'name': name,
      'identifier': identifier,
      'unitOrRole': unitOrRole,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory WhitelistEntry.fromMap(Map<dynamic, dynamic> map) {
    return WhitelistEntry(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      identifier: map['identifier'] as String,
      unitOrRole: map['unitOrRole'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }
}
