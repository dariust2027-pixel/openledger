# ML Kit text recognition: optional script recognizers are referenced by the
# base TextRecognizer class but not bundled unless their feature module is
# included. Tell R8 to ignore the missing references instead of failing.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Keep Flutter plugin classes reached via reflection.
-keep class io.flutter.plugin.** { *; }
