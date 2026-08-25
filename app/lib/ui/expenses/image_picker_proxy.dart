import 'package:image_picker/image_picker.dart';

/// Thin indirection over image_picker so UI code stays testable and the
/// plugin call is isolated.
class ImagePickerProxy {
  static Future<String?> pick(bool fromCamera) async {
    final picker = ImagePicker();
    final x = await picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2048,
      imageQuality: 85,
    );
    return x?.path;
  }
}

class OcrUnavailableException implements Exception {
  final String message;
  OcrUnavailableException(this.message);
}
