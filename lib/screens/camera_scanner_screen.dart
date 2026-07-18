import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../theme/colors.dart';

class CameraScannerScreen extends StatefulWidget {
  const CameraScannerScreen({super.key});

  @override
  State<CameraScannerScreen> createState() => _CameraScannerScreenState();
}

class _CameraScannerScreenState extends State<CameraScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _isScanCompleted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: slate900,
        foregroundColor: Colors.white,
        title: const Text('Escaneo de Código QR', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (context, state, child) {
                switch (state.torchState) {
                  case TorchState.off:
                    return const Icon(Icons.flash_off, color: Colors.grey);
                  case TorchState.on:
                    return const Icon(Icons.flash_on, color: Colors.amber);
                  default:
                    return const Icon(Icons.flash_off, color: Colors.grey);
                }
              },
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (context, state, child) {
                switch (state.cameraDirection) {
                  case CameraFacing.front:
                    return const Icon(Icons.camera_front);
                  case CameraFacing.back:
                    return const Icon(Icons.camera_rear);
                  default:
                    return const Icon(Icons.camera_rear);
                }
              },
            ),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_isScanCompleted) return;

              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final String? rawValue = barcodes.first.rawValue;
                if (rawValue != null && rawValue.isNotEmpty) {
                  setState(() {
                    _isScanCompleted = true;
                  });
                  Navigator.pop(context, rawValue);
                }
              }
            },
          ),
          
          // Outer overlay with scanning window cutout
          Positioned.fill(
            child: Container(
              decoration: ShapeDecoration(
                shape: const QrScannerOverlayShape(
                  borderColor: Color(0xFF10B981),
                  borderRadius: 16,
                  borderLength: 30,
                  borderWidth: 8,
                  cutOutSize: 260,
                ),
              ),
            ),
          ),

          // Central prompt text
          const Positioned(
            bottom: 60,
            left: 24,
            right: 24,
            child: Column(
              children: [
                Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF10B981), size: 36),
                SizedBox(height: 12),
                Text(
                  'Alinea el código QR dentro del recuadro para escanear',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Se detectará y autorizará de forma automática',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Custom Shape for Viewfinder Overlay
class QrScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final double borderLength;
  final double borderRadius;
  final double cutOutSize;

  const QrScannerOverlayShape({
    this.borderColor = const Color(0xFF10B981),
    this.borderWidth = 8,
    this.borderLength = 30,
    this.borderRadius = 16,
    this.cutOutSize = 250,
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path();

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRect(rect);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final backgroundPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.65)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round;

    final double width = rect.width;
    final double height = rect.height;
    final double left = (width - cutOutSize) / 2;
    final double top = (height - cutOutSize) / 2;
    final double right = left + cutOutSize;
    final double bottom = top + cutOutSize;

    // Background cutout
    final cutoutRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(left, top, right, bottom),
      Radius.circular(borderRadius),
    );

    final path = Path()
      ..addRect(rect)
      ..addRRect(cutoutRect);

    canvas.drawPath(path, backgroundPaint);

    // Draw Corner Brackets
    // Top Left Corner
    canvas.drawPath(
      Path()
        ..moveTo(left + borderRadius + borderLength, top)
        ..lineTo(left + borderRadius, top)
        ..arcToPoint(Offset(left, top + borderRadius), radius: Radius.circular(borderRadius), clockwise: false)
        ..lineTo(left, top + borderRadius + borderLength),
      borderPaint,
    );

    // Top Right Corner
    canvas.drawPath(
      Path()
        ..moveTo(right - borderRadius - borderLength, top)
        ..lineTo(right - borderRadius, top)
        ..arcToPoint(Offset(right, top + borderRadius), radius: Radius.circular(borderRadius))
        ..lineTo(right, top + borderRadius + borderLength),
      borderPaint,
    );

    // Bottom Left Corner
    canvas.drawPath(
      Path()
        ..moveTo(left + borderRadius + borderLength, bottom)
        ..lineTo(left + borderRadius, bottom)
        ..arcToPoint(Offset(left, bottom - borderRadius), radius: Radius.circular(borderRadius))
        ..lineTo(left, bottom - borderRadius - borderLength),
      borderPaint,
    );

    // Bottom Right Corner
    canvas.drawPath(
      Path()
        ..moveTo(right - borderRadius - borderLength, bottom)
        ..lineTo(right - borderRadius, bottom)
        ..arcToPoint(Offset(right, bottom - borderRadius), radius: Radius.circular(borderRadius), clockwise: false)
        ..lineTo(right, bottom - borderRadius - borderLength),
      borderPaint,
    );
  }

  @override
  ShapeBorder scale(double t) => this;
}
