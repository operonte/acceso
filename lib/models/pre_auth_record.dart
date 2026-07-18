class PreAuthRecord {
  final String id;
  final String type; // 'persona' or 'vehiculo'
  final String name;
  final String docId;
  final String? plate;
  final String? vehicleType;
  final String destination;
  final DateTime visitDate;
  bool isUsed;

  PreAuthRecord({
    required this.id,
    required this.type,
    required this.name,
    required this.docId,
    this.plate,
    this.vehicleType,
    required this.destination,
    required this.visitDate,
    this.isUsed = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'name': name,
      'docId': docId,
      'plate': plate,
      'vehicleType': vehicleType,
      'destination': destination,
      'visitDate': visitDate.toIso8601String(),
      'isUsed': isUsed,
    };
  }

  factory PreAuthRecord.fromMap(Map<dynamic, dynamic> map) {
    return PreAuthRecord(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      docId: map['docId'] as String,
      plate: map['plate'] as String?,
      vehicleType: map['vehicleType'] as String?,
      destination: map['destination'] as String,
      visitDate: DateTime.parse(map['visitDate'] as String),
      isUsed: map['isUsed'] as bool,
    );
  }
}
