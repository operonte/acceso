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
  final String? phone; // Optional contact phone

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
    this.phone,
  });

  String get durationText {
    final end = exitTime ?? DateTime.now();
    final diff = end.difference(entryTime);
    if (diff.inDays > 0) {
      return '${diff.inDays}d ${diff.inHours % 24}h ${diff.inMinutes % 60}m';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}h ${diff.inMinutes % 60}m';
    } else {
      return '${diff.inMinutes}m';
    }
  }

  int get durationMinutes {
    final end = exitTime ?? DateTime.now();
    return end.difference(entryTime).inMinutes;
  }

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
      'phone': phone,
      'durationStay': durationText,
      'durationMinutes': durationMinutes,
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
      phone: map['phone'] as String?,
    );
  }
}
