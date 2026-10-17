# kotlinx.serialization models are reached through generated serializers.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class **$$serializer { *; }
-keep,includedescriptorclasses class app.libarrie.**$$serializer { *; }
-keepclassmembers class app.libarrie.** { *** Companion; kotlinx.serialization.KSerializer serializer(...); }
