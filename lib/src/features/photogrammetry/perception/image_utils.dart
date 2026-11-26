import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../../core/failures/pipeline_failure.dart';

/// Upright RGB image (EXIF orientation applied).
class RgbImage {
  final int width, height;
  final Uint8List rgb;
  RgbImage(this.width, this.height, this.rgb) {
    if (rgb.length != width * height * 3) throw ArgumentError('rgb size mismatch');
  }

  Uint8List toRgba() {
    final out = Uint8List(width * height * 4);
    for (int i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
      out[j] = rgb[i];
      out[j + 1] = rgb[i + 1];
      out[j + 2] = rgb[i + 2];
      out[j + 3] = 255;
    }
    return out;
  }

  /// BGRA (ML Kit's Android bitmap path expects this byte order).
  Uint8List toBgra() {
    final out = Uint8List(width * height * 4);
    for (int i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
      out[j] = rgb[i + 2];
      out[j + 1] = rgb[i + 1];
      out[j + 2] = rgb[i];
      out[j + 3] = 255;
    }
    return out;
  }

  /// Bilinear resize so the long edge is [longEdge] (never upsamples).
  RgbImage resizedLongEdge(int longEdge) {
    final scale = longEdge / (width > height ? width : height);
    if (scale >= 1.0) return this;
    final src = img.Image.fromBytes(width: width, height: height, bytes: rgb.buffer, numChannels: 3);
    final dst = img.copyResize(src, width: (width * scale).round(), height: (height * scale).round(), interpolation: img.Interpolation.linear);
    return RgbImage(dst.width, dst.height, Uint8List.fromList(dst.getBytes(order: img.ChannelOrder.rgb)));
  }
}

/// Decodes a JPEG and bakes its EXIF orientation (Camera2 may rotate pixels or
/// only set the tag, depending on the device). Pure Dart; run in an isolate.
RgbImage decodeJpegUpright(Uint8List jpeg) {
  final decoded = img.decodeJpg(jpeg);
  if (decoded == null) throw const CaptureFailure('jpeg_decode', 'JPEG decode failed', 'A photo could not be read.');
  final upright = img.bakeOrientation(decoded);
  return RgbImage(upright.width, upright.height, Uint8List.fromList(upright.getBytes(order: img.ChannelOrder.rgb)));
}

/// Nearest-neighbour resize of a binary mask ([keepValues]: copy label values instead of 0/1).
Uint8List resizeMask(Uint8List mask, int w, int h, int nw, int nh, {bool keepValues = false}) {
  final out = Uint8List(nw * nh);
  for (int y = 0; y < nh; y++) {
    final sy = ((y + 0.5) * h / nh).floor().clamp(0, h - 1);
    for (int x = 0; x < nw; x++) {
      final sx = ((x + 0.5) * w / nw).floor().clamp(0, w - 1);
      final v = mask[sy * w + sx];
      out[y * nw + x] = keepValues ? v : (v != 0 ? 1 : 0);
    }
  }
  return out;
}

/// Keeps only the connected component (4-connectivity) containing [seedX, seedY],
/// or the largest component if the seed is background. Returns (mask, area).
(Uint8List, int) largestComponent(Uint8List mask, int w, int h, {int? seedX, int? seedY}) {
  final label = Int32List(w * h);
  int next = 0, bestLabel = 0, bestArea = 0, seedLabel = 0;
  final stack = <int>[];
  for (int i = 0; i < w * h; i++) {
    if (mask[i] == 0 || label[i] != 0) continue;
    next++;
    int area = 0;
    stack.add(i);
    label[i] = next;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      area++;
      final x = p % w, y = p ~/ w;
      for (final q in [if (x > 0) p - 1, if (x < w - 1) p + 1, if (y > 0) p - w, if (y < h - 1) p + w]) {
        if (mask[q] != 0 && label[q] == 0) {
          label[q] = next;
          stack.add(q);
        }
      }
    }
    if (area > bestArea) {
      bestArea = area;
      bestLabel = next;
    }
  }
  if (seedX != null && seedY != null && seedX >= 0 && seedY >= 0 && seedX < w && seedY < h) {
    seedLabel = label[seedY * w + seedX];
  }
  final keep = seedLabel != 0 ? seedLabel : bestLabel;
  final out = Uint8List(w * h);
  int area = 0;
  for (int i = 0; i < w * h; i++) {
    if (keep != 0 && label[i] == keep) {
      out[i] = 1;
      area++;
    }
  }
  return (out, area);
}
