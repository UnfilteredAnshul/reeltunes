# ReelTunes release keep rules.
#
# R8 full mode (AGP 9) stripped the no-arg constructor of Room's generated
# database class `androidx.work.impl.WorkDatabase_Impl`, even though the Room
# consumer rule (`-keep class * extends androidx.room.RoomDatabase`) is present.
# Room instantiates that class by reflection (Room.getGeneratedImplementation),
# so WorkManager's automatic startup threw
#
#   java.lang.RuntimeException: Failed to create an instance of
#   androidx.work.impl.WorkDatabase
#   at androidx.room.Room.getGeneratedImplementation(Room.java:100)
#
# inside androidx.startup.InitializationProvider.onCreate, i.e. before the
# Flutter engine started. That killed the app on launch (versionCode 5).
#
# WorkManager arrives through play-services-ads; the app never uses it directly,
# so keep Room's database classes fully intact instead of disabling the
# initializer.

-keep class * extends androidx.room.RoomDatabase { *; }
-keep class androidx.room.RoomDatabase { *; }
-keepclassmembers class * extends androidx.room.RoomDatabase {
    <init>();
}
