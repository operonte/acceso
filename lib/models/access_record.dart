class AccessRecord {
  final String id;
  final String type; // 'persona' or 'vehiculo'
  final String name; // Name of person or driver
  final String docId; // RUT / DNI
  final String? plate; // License plate (null for pedestrians)
  final String? vehicleType; // Auto, Camioneta, Camión, Moto, etc.
  final String destination; // Where are they going?
  final DateTime entryTime;
  DateTime? exitTime;
  bool isInside;
  String? photoPath;
  final String? comment; // Optional comment

  AccessRecord({
    required this.id,
    required this.type,
    required this.name,
    required this.docId,
    this.plate,
    this.vehicleType,
    required this.destination,
    required this.entryTime,
    this.exitTime,
    this.isInside = true,
    this.photoPath,
    this.comment,
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
      'entryTime': entryTime.toIso8601String(),
      'exitTime': exitTime?.toIso8601String(),
      'isInside': isInside,
      'photoPath': photoPath,
      'comment': comment,
    };
  }

  factory AccessRecord.fromMap(Map<dynamic, dynamic> map) {
    return AccessRecord(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      docId: map['docId'] as String,
      plate: map['plate'] as String?,
      vehicleType: map['vehicleType'] as String?,
      destination: map['destination'] as String,
      entryTime: DateTime.parse(map['entryTime'] as String).toLocal(),
      exitTime: map['exitTime'] != null ? DateTime.parse(map['exitTime'] as String).toLocal() : null,
      isInside: map['isInside'] as bool,
      photoPath: map['photoPath'] as String?,
      comment: map['comment'] as String?,
    );
  }
}
