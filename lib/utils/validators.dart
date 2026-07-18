import 'package:flutter/services.dart';

bool isValidRut(String rut) {
  final cleanRut = rut.replaceAll(RegExp(r'[^0-9kK]'), '').toUpperCase();
  if (cleanRut.length < 2) return false;
  
  final dv = cleanRut.substring(cleanRut.length - 1);
  final rutBodyStr = cleanRut.substring(0, cleanRut.length - 1);
  final rutBody = int.tryParse(rutBodyStr);
  if (rutBody == null) return false;
  
  int sum = 0;
  int multiplier = 2;
  for (int i = rutBodyStr.length - 1; i >= 0; i--) {
    sum += int.parse(rutBodyStr[i]) * multiplier;
    multiplier = multiplier == 7 ? 2 : multiplier + 1;
  }
  
  final expectedDvInt = 11 - (sum % 11);
  String expectedDv;
  if (expectedDvInt == 11) {
    expectedDv = '0';
  } else if (expectedDvInt == 10) {
    expectedDv = 'K';
  } else {
    expectedDv = expectedDvInt.toString();
  }
  
  return dv == expectedDv;
}

bool isValidDocument(String docId, bool isRut) {
  if (isRut) {
    return isValidRut(docId);
  }
  final genericClean = docId.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
  return genericClean.length >= 5;
}

bool isValidPlate(String plate) {
  final clean = plate.replaceAll(RegExp(r'[^A-Z0-9]'), '').toUpperCase();
  return clean.length >= 4 && clean.length <= 8;
}

class RutFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;

    String cleaned = text.replaceAll(RegExp(r'[^0-9kK]'), '').toUpperCase();
    if (cleaned.isEmpty) {
      return const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
    }

    String formatted = '';
    final len = cleaned.length;
    
    if (len <= 1) {
      formatted = cleaned;
    } else {
      final dv = cleaned.substring(len - 1);
      final body = cleaned.substring(0, len - 1);
      
      String formattedBody = '';
      int count = 0;
      for (int i = body.length - 1; i >= 0; i--) {
        formattedBody = '${body[i]}$formattedBody';
        count++;
        if (count % 3 == 0 && i > 0) {
          formattedBody = '.$formattedBody';
        }
      }
      formatted = '$formattedBody-$dv';
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class PlateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (text.isEmpty) return newValue;
    
    final clean = text.substring(0, text.length > 6 ? 6 : text.length);
    final formatted = _formatPlateString(clean);
    
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  String _formatPlateString(String clean) {
    if (clean.length <= 2) return clean;
    if (clean.length <= 4) {
      return '${clean.substring(0, 2)}-${clean.substring(2)}';
    }
    
    final isOldFormat = RegExp(r'^[A-Z]{2}\d').hasMatch(clean);
    if (isOldFormat) {
      if (clean.length == 5) {
        return '${clean.substring(0, 2)}-${clean.substring(2, 4)}-${clean.substring(4)}';
      }
      return '${clean.substring(0, 2)}-${clean.substring(2, 4)}-${clean.substring(4, 6)}';
    } else {
      return '${clean.substring(0, 4)}-${clean.substring(4)}';
    }
  }
}
