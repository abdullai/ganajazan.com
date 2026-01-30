// lib/services/watermark_service.dart
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class WatermarkService {
  static Future<Uint8List> addTextWatermark(
    Uint8List inputBytes, {
    String text = 'Aqar موثوق',
    int margin = 16,
    int fontSize = 24, // 14/24/48 supported
    int opacity = 170, // 0..255
  }) async {
    final decoded = img.decodeImage(inputBytes);
    if (decoded == null) return inputBytes;

    // ✅ Compatible with older Dart (no switch-expressions)
    img.BitmapFont font;
    if (fontSize <= 14) {
      font = img.arial14;
    } else if (fontSize >= 48) {
      font = img.arial48;
    } else {
      font = img.arial24;
    }

    final int y = (decoded.height - margin - font.lineHeight);
    final int safeY = y < 0 ? 0 : y;

    // Shadow
    img.drawString(
      decoded,
      text,
      font: font,
      x: null, // center horizontally
      y: safeY + 1,
      color: img.ColorRgba8(0, 0, 0, (opacity * 0.55).round()),
      blend: img.BlendMode.alpha,
    );

    // Main text
    img.drawString(
      decoded,
      text,
      font: font,
      x: null, // center horizontally
      y: safeY,
      color: img.ColorRgba8(255, 255, 255, opacity),
      blend: img.BlendMode.alpha,
    );

    final out = img.encodeJpg(decoded, quality: 92);
    return Uint8List.fromList(out);
  }
}
