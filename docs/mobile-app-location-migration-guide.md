# Flutter App Location Tracking Migration Guide
## From MQTT (EMQX) to Google Pub/Sub

## Table of Contents
1. [Overview](#1-overview)
2. [Current MQTT Implementation Analysis](#2-current-mqtt-implementation-analysis)
3. [Google Pub/Sub Integration](#3-google-pubsub-integration)
4. [Flutter Implementation Guide](#4-flutter-implementation-guide)
5. [Platform-Specific Setup](#5-platform-specific-setup)
6. [Migration Strategy](#6-migration-strategy)
7. [Testing Strategy](#7-testing-strategy)
8. [Rollout Plan](#8-rollout-plan)
9. [Monitoring & Debugging](#9-monitoring-debugging)
10. [FAQ & Troubleshooting](#10-faq-troubleshooting)

## 1. Overview

### Migration Goals
- Replace MQTT with Google Pub/Sub for better scalability
- Maintain backward compatibility during transition
- Improve reliability with automatic retries
- Reduce battery consumption
- Enable better offline support

### Key Benefits
| Feature | MQTT (Current) | Pub/Sub (New) |
|---------|---------------|---------------|
| Setup Complexity | High (broker management) | Low (fully managed) |
| Scalability | Limited | Unlimited |
| Offline Support | Basic | Advanced with retry |
| Battery Usage | Higher (persistent connection) | Lower (HTTP-based) |
| Cost | Server + Management | Pay per message |
| Global Reach | Requires multiple brokers | Built-in global |

## 2. Current MQTT Implementation Analysis

### Current Architecture
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Mobile App  │────▶│ MQTT Broker │────▶│  Backend    │
│             │     │   (EMQX)    │     │ (TypeScript)│
└─────────────┘     └─────────────┘     └─────────────┘
     │                                           │
     └───────────── TCP Socket ─────────────────┘
```

### Typical MQTT Implementation
```swift
// Current iOS MQTT code
class MQTTLocationManager {
    private let mqtt: CocoaMQTT
    private let topic = "device/telemetry"
    
    init() {
        mqtt = CocoaMQTT(clientID: UIDevice.current.identifierForVendor!.uuidString,
                         host: "mqtt.innovd.com",
                         port: 8883)
        mqtt.username = "device_user"
        mqtt.password = "device_password"
        mqtt.enableSSL = true
    }
    
    func sendLocation(_ location: CLLocation) {
        let payload: [String: Any] = [
            "deviceId": deviceId,
            "timestamp": ISO8601DateFormatter().string(from: location.timestamp),
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "speed": location.speed,
            "accuracy": location.horizontalAccuracy,
            "batteryLevel": UIDevice.current.batteryLevel
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            mqtt.publish(topic, withString: String(data: data, encoding: .utf8)!)
        }
    }
}
```

## 3. Google Pub/Sub Integration

### New Architecture
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Mobile App  │────▶│Google Pub/Sub│────▶│ Go Backend  │
│             │     │              │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
     │                                           │
     └────────────── HTTPS/gRPC ────────────────┘
```

### Pub/Sub Advantages
1. **No Connection Management**: HTTP-based, no persistent connections
2. **Automatic Retries**: Built-in exponential backoff
3. **Message Ordering**: Guaranteed order per device
4. **Dead Letter Topics**: Automatic handling of failed messages
5. **Global Load Balancing**: Automatic routing to nearest endpoint

## 4. Flutter Implementation Guide

### 4.1 Package Setup

#### pubspec.yaml Configuration
```yaml
# pubspec.yaml
name: innovd_app
description: InnoVriddhi Location Tracking App

dependencies:
  flutter:
    sdk: flutter
  
  # Google Cloud Pub/Sub
  googleapis: ^11.4.0
  googleapis_auth: ^1.4.1
  
  # Location services
  geolocator: ^10.1.0
  permission_handler: ^11.0.1
  
  # For backward compatibility
  mqtt_client: ^10.0.0
  
  # Feature flags
  launchdarkly_flutter_client_sdk: ^3.0.0
  
  # Utilities
  connectivity_plus: ^5.0.2
  device_info_plus: ^9.1.1
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  
  # Platform detection
  universal_io: ^2.2.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.1
  build_runner: ^2.4.7
  hive_generator: ^2.0.1
```

### 4.2 Dual Publishing Strategy

```dart
// lib/services/dual_publisher.dart
import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:googleapis/pubsub/v1.dart';
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';

class DualPublisher {
  final MqttServerClient _mqttClient;
  final PubsubApi _pubsubApi;
  final LDClient _ldClient;
  final String deviceId;
  
  bool _usePubSubPrimary = false;
  int _pubSubSuccessCount = 0;
  int _pubSubFailureCount = 0;
  
  DualPublisher({
    required this.deviceId,
    required MqttServerClient mqttClient,
    required PubsubApi pubsubApi,
    required LDClient ldClient,
  }) : _mqttClient = mqttClient,
       _pubsubApi = pubsubApi,
       _ldClient = ldClient;
  
  Future<void> publishLocation(LocationUpdate update) async {
    // Check feature flag
    _usePubSubPrimary = await _ldClient.boolVariation(
      'use-pubsub-primary',
      false,
    );
    
    if (_usePubSubPrimary) {
      // Try Pub/Sub first
      final pubSubSuccess = await _publishToPubSub(update);
      
      if (!pubSubSuccess) {
        // Fallback to MQTT
        await _publishToMqtt(update);
      }
      
      // Also publish to MQTT for comparison (during migration)
      if (await _ldClient.boolVariation('dual-publish', false)) {
        await _publishToMqtt(update);
      }
    } else {
      // Use MQTT as primary
      await _publishToMqtt(update);
      
      // Also try Pub/Sub for testing
      if (await _ldClient.boolVariation('test-pubsub', false)) {
        await _publishToPubSub(update);
      }
    }
  }
  
  Future<bool> _publishToPubSub(LocationUpdate update) async {
    try {
      final message = PubsubMessage()
        ..data = base64Encode(utf8.encode(jsonEncode(update.toJson())))
        ..attributes = {
          'device_id': deviceId,
          'timestamp': update.timestamp.toIso8601String(),
          'client': 'flutter',
        };
      
      final request = PublishRequest()..messages = [message];
      
      await _pubsubApi.projects.topics.publish(
        request,
        'projects/innovd-prod/topics/location-updates',
      );
      
      _pubSubSuccessCount++;
      _trackMetrics('pubsub_success');
      return true;
    } catch (e) {
      _pubSubFailureCount++;
      _trackMetrics('pubsub_failure', error: e.toString());
      return false;
    }
  }
  
  Future<bool> _publishToMqtt(LocationUpdate update) async {
    try {
      if (_mqttClient.connectionStatus?.state != 
          MqttConnectionState.connected) {
        await _mqttClient.connect();
      }
      
      final builder = MqttClientPayloadBuilder()
        ..addString(jsonEncode(update.toJson()));
      
      _mqttClient.publishMessage(
        'devices/$deviceId/location',
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      
      _trackMetrics('mqtt_success');
      return true;
    } catch (e) {
      _trackMetrics('mqtt_failure', error: e.toString());
      return false;
    }
  }
  
  void _trackMetrics(String event, {String? error}) {
    // Send metrics to analytics
    _ldClient.track(event, data: {
      'device_id': deviceId,
      'pubsub_primary': _usePubSubPrimary,
      'pubsub_success_count': _pubSubSuccessCount,
      'pubsub_failure_count': _pubSubFailureCount,
      if (error != null) 'error': error,
    });
  }
}
    private let pubsub: PubSubClient
    private let mqtt: MQTTManager? // Fallback
    private let featureFlags: FeatureFlagManager
    
    private let locationUpdateTopic = "location-updates"
    private var pendingUpdates: [LocationUpdate] = []
    private let maxBatchSize = 100
    private let batchInterval: TimeInterval = 30.0
    
    override init() {
        // Initialize Pub/Sub
        self.pubsub = PubSubClient(
            projectId: "innovd-location-tracking",
            credentialsPath: Bundle.main.path(forResource: "credentials", ofType: "json")
        )
        
        // Initialize MQTT as fallback
        self.mqtt = MQTTManager()
        
        // Feature flags
        self.featureFlags = FeatureFlagManager.shared
        
        super.init()
        
        // Start batch timer
        Timer.scheduledTimer(withTimeInterval: batchInterval, repeats: true) { _ in
            self.flushPendingUpdates()
        }
    }
    
    // MARK: - Location Update Methods
    func sendLocation(_ location: CLLocation) {
        let update = LocationUpdate(
            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
            timestamp: ISO8601DateFormatter().string(from: location.timestamp),
            coordinates: LocationUpdate.Coordinates(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            speed: max(0, location.speed * 3.6), // Convert m/s to km/h
            accuracy: location.horizontalAccuracy,
            heading: location.course >= 0 ? location.course : 0,
            altitude: location.altitude,
            batteryLevel: UIDevice.current.batteryLevel,
            networkType: getNetworkType(),
            isCharging: UIDevice.current.batteryState == .charging,
            metadata: LocationUpdate.Metadata(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                osVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model
            )
        )
        
        if featureFlags.isEnabled("use_pubsub_batch") {
            queueLocationUpdate(update)
        } else {
            sendLocationImmediate(update)
        }
    }
    
    private func sendLocationImmediate(_ update: LocationUpdate) {
        if featureFlags.isEnabled("use_pubsub") {
            sendViaPubSub(updates: [update]) { [weak self] success in
                if !success {
                    self?.sendViaMQTT(update)
                }
            }
        } else {
            sendViaMQTT(update)
        }
    }
    
    private func queueLocationUpdate(_ update: LocationUpdate) {
        pendingUpdates.append(update)
        
        if pendingUpdates.count >= maxBatchSize {
            flushPendingUpdates()
        }
    }
    
    private func flushPendingUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        
        sendViaPubSub(updates: updates) { [weak self] success in
            if !success {
                // Fallback to MQTT for failed updates
                updates.forEach { self?.sendViaMQTT($0) }
            }
        }
    }
    
    // MARK: - Pub/Sub Implementation
    private func sendViaPubSub(updates: [LocationUpdate], completion: @escaping (Bool) -> Void) {
        do {
            let encoder = JSONEncoder()
            let messages = try updates.map { update -> PubSubMessage in
                let data = try encoder.encode(update)
                return PubSubMessage(
                    data: data,
                    attributes: [
                        "deviceId": update.deviceId,
                        "timestamp": update.timestamp
                    ]
                )
            }
            
            pubsub.publish(
                topic: locationUpdateTopic,
                messages: messages
            ) { error in
                if let error = error {
                    print("Pub/Sub error: \(error)")
                    completion(false)
                } else {
                    print("Successfully sent \(updates.count) updates via Pub/Sub")
                    completion(true)
                }
            }
        } catch {
            print("Encoding error: \(error)")
            completion(false)
        }
    }
    
    // MARK: - MQTT Fallback
    private func sendViaMQTT(_ update: LocationUpdate) {
        mqtt?.sendLocation(update)
    }
    
    // MARK: - Utility Methods
    private func getNetworkType() -> String {
        // Implementation to detect network type
        return "WiFi" // Simplified
    }
}

// MARK: - Background Location Updates
extension PubSubLocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Filter out old and inaccurate locations
        let filteredLocations = locations.filter { location in
            let timeSinceUpdate = Date().timeIntervalSince(location.timestamp)
            return timeSinceUpdate < 5.0 && location.horizontalAccuracy <= 50
        }
        
        // Send each valid location
        filteredLocations.forEach { sendLocation($0) }
    }
}
```

### 4.3 Battery Optimization

```dart
// lib/services/battery_optimized_tracker.dart
import 'package:geolocator/geolocator.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';

class BatteryOptimizedTracker {
  final Battery _battery = Battery();
  LocationSettings? _currentSettings;
  StreamSubscription<Position>? _positionStream;
  Timer? _adaptiveTimer;
  
  // Adaptive tracking parameters
  int _batteryLevel = 100;
  bool _isCharging = false;
  double _currentSpeed = 0;
  LocationAccuracy _currentAccuracy = LocationAccuracy.high;
  int _currentInterval = 10; // seconds
  
  Future<void> startAdaptiveTracking() async {
    // Monitor battery state
    _battery.onBatteryStateChanged.listen((BatteryState state) {
      _isCharging = state == BatteryState.charging;
      _updateTrackingMode();
    });
    
    // Get initial battery level
    _batteryLevel = await _battery.batteryLevel ?? 100;
    
    // Start with optimal settings
    _updateTrackingMode();
    
    // Adaptive interval adjustment
    _adaptiveTimer = Timer.periodic(Duration(minutes: 5), (_) {
      _adjustTrackingParameters();
    });
  }
  
  void _updateTrackingMode() {
    // Cancel existing stream
    _positionStream?.cancel();
    
    // Determine optimal settings based on battery and motion
    _currentSettings = _calculateOptimalSettings();
    
    // Restart tracking with new settings
    _positionStream = Geolocator.getPositionStream(
      locationSettings: _currentSettings!,
    ).listen((Position position) {
      _currentSpeed = position.speed;
      _handleLocationUpdate(position);
    });
  }
  
  LocationSettings _calculateOptimalSettings() {
    // Adaptive accuracy based on battery and charging state
    if (_isCharging) {
      _currentAccuracy = LocationAccuracy.best;
      _currentInterval = 5;
    } else if (_batteryLevel > 50) {
      _currentAccuracy = LocationAccuracy.high;
      _currentInterval = 10;
    } else if (_batteryLevel > 20) {
      _currentAccuracy = LocationAccuracy.medium;
      _currentInterval = 30;
    } else {
      _currentAccuracy = LocationAccuracy.low;
      _currentInterval = 60;
    }
    
    // Adjust based on movement
    if (_currentSpeed > 50) { // Moving fast (vehicle)
      _currentInterval = max(5, _currentInterval ~/ 2);
    } else if (_currentSpeed < 1) { // Stationary
      _currentInterval = min(300, _currentInterval * 3);
    }
    
    return LocationSettings(
      accuracy: _currentAccuracy,
      distanceFilter: _calculateDistanceFilter(),
      timeLimit: Duration(seconds: 30),
    );
  }
  
  int _calculateDistanceFilter() {
    // Dynamic distance filter based on speed
    if (_currentSpeed > 50) return 100; // 100m for vehicle
    if (_currentSpeed > 10) return 50;  // 50m for cycling
    if (_currentSpeed > 2) return 20;   // 20m for walking
    return 10; // 10m when stationary/slow
  }
  
  void _adjustTrackingParameters() async {
    // Update battery level
    _batteryLevel = await _battery.batteryLevel ?? _batteryLevel;
    
    // Check if we need to change tracking mode
    final oldAccuracy = _currentAccuracy;
    final newSettings = _calculateOptimalSettings();
    
    if (newSettings.accuracy != oldAccuracy) {
      print('Adjusting tracking mode: $oldAccuracy -> ${newSettings.accuracy}');
      _updateTrackingMode();
    }
  }
  
  void _handleLocationUpdate(Position position) {
    // Process location update
    final update = LocationUpdate(
      deviceId: deviceId,
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      speed: position.speed,
      bearing: position.heading,
      altitude: position.altitude,
      timestamp: position.timestamp ?? DateTime.now(),
      batteryLevel: _batteryLevel,
      isCharging: _isCharging,
      trackingMode: _currentAccuracy.toString(),
    );
    
    // Send via dual publisher
    _dualPublisher.publishLocation(update);
  }
  
  void dispose() {
    _positionStream?.cancel();
    _adaptiveTimer?.cancel();
  }
}

## 5. Platform-Specific Setup

### 5.1 iOS Configuration

```xml
<!-- ios/Runner/Info.plist -->
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>This app needs location access to track delivery routes</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access to track your current position</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>fetch</string>
</array>

<!-- Enable background location updates -->
<key>NSLocationAlwaysUsageDescription</key>
<string>This app needs continuous location access for route tracking</string>
```

```swift
// ios/Runner/AppDelegate.swift
import UIKit
import Flutter
import GoogleMaps

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Configure Google Maps
        GMSServices.provideAPIKey("YOUR_GOOGLE_MAPS_API_KEY")
        
        // Enable background modes
        if #available(iOS 9.0, *) {
            application.setMinimumBackgroundFetchInterval(
                UIApplication.backgroundFetchIntervalMinimum
            )
        }
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
```

### 5.2 Android Configuration

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Permissions -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
    
    <application
        android:name=".MainApplication"
        android:label="@string/app_name"
        android:icon="@mipmap/ic_launcher">
        
        <!-- Foreground service for location tracking -->
        <service
            android:name="com.innovd.LocationTrackingService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="location" />
        
        <!-- Google Maps API Key -->
        <meta-data
            android:name="com.google.android.geo.API_KEY"
            android:value="YOUR_GOOGLE_MAPS_API_KEY" />
    </application>
</manifest>
```

```kotlin
// android/app/src/main/kotlin/com/innovd/LocationTrackingService.kt
package com.innovd

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class LocationTrackingService : Service() {
    private val CHANNEL_ID = "location_tracking_channel"
    private val NOTIFICATION_ID = 1
    private lateinit var flutterEngine: FlutterEngine
    
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
        
        // Initialize Flutter engine for background execution
        flutterEngine = FlutterEngine(this)
        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        
        // Setup method channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.innovd/location_service"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTracking" -> {
                    startLocationTracking()
                    result.success(null)
                }
                "stopTracking" -> {
                    stopLocationTracking()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Location Tracking Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }
    
    private fun createNotification(): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Location Tracking Active")
            .setContentText("Tracking your location in background")
            .setSmallIcon(R.drawable.ic_location)
            .setContentIntent(pendingIntent)
            .build()
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
}
```

### 5.3 Platform Channel Implementation

```dart
// lib/services/platform_location_service.dart
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

class PlatformLocationService {
  static const platform = MethodChannel('com.innovd/location_service');
  
  // Platform-specific background tracking
  static Future<void> startBackgroundTracking() async {
    try {
      if (Platform.isAndroid) {
        await platform.invokeMethod('startTracking');
      } else if (Platform.isIOS) {
        // iOS handles background tracking differently
        await _configureIOSBackgroundModes();
      }
    } on PlatformException catch (e) {
      print('Failed to start background tracking: ${e.message}');
    }
  }
  
  static Future<void> stopBackgroundTracking() async {
    try {
      await platform.invokeMethod('stopTracking');
    } on PlatformException catch (e) {
      print('Failed to stop background tracking: ${e.message}');
    }
  }
  
  static Future<void> _configureIOSBackgroundModes() async {
    // iOS-specific configuration
    await platform.invokeMethod('configureBackgroundModes', {
      'allowsBackgroundLocationUpdates': true,
      'pausesLocationUpdatesAutomatically': false,
      'showsBackgroundLocationIndicator': true,
    });
  }
  
  // Request battery optimization exemption (Android)
  static Future<void> requestBatteryOptimizationExemption() async {
    if (Platform.isAndroid) {
      try {
        final bool isIgnoring = await platform.invokeMethod(
          'isIgnoringBatteryOptimizations'
        );
        
        if (!isIgnoring) {
          await platform.invokeMethod('requestIgnoreBatteryOptimizations');
        }
      } on PlatformException catch (e) {
        print('Battery optimization request failed: ${e.message}');
      }
    }
  }
}
```
```

## 6. Migration Strategy

### 6.1 Phased Migration Approach

```dart
// lib/services/migration_controller.dart
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';

class MigrationController {
  final LDClient _ldClient;
  final Analytics _analytics;
  
  // Migration phases
  static const String PHASE_TESTING = 'testing';
  static const String PHASE_CANARY = 'canary';
  static const String PHASE_ROLLOUT = 'rollout';
  static const String PHASE_COMPLETE = 'complete';
  
  String _currentPhase = PHASE_TESTING;
  
  MigrationController({
    required LDClient ldClient,
    required Analytics analytics,
  }) : _ldClient = ldClient,
       _analytics = analytics;
  
  Future<MigrationConfig> getMigrationConfig() async {
    final config = await _ldClient.jsonVariation(
      'location-tracking-migration',
      defaultValue: _getDefaultConfig(),
    );
    
    return MigrationConfig.fromJson(config);
  }
  
  Map<String, dynamic> _getDefaultConfig() => {
    'phase': PHASE_TESTING,
    'pubSubPercentage': 0,
    'dualPublish': true,
    'metricsEnabled': true,
    'fallbackEnabled': true,
    'batchingEnabled': false,
  };
  
  Future<void> recordMigrationMetrics({
    required String source,
    required bool success,
    required int latency,
    Map<String, dynamic>? metadata,
  }) async {
    await _analytics.track('location_publish', {
      'source': source,
      'success': success,
      'latency_ms': latency,
      'phase': _currentPhase,
      'device_id': await DeviceInfo.getUniqueId(),
      ...?metadata,
    });
  }
}

class MigrationConfig {
  final String phase;
  final int pubSubPercentage;
  final bool dualPublish;
  final bool metricsEnabled;
  final bool fallbackEnabled;
  final bool batchingEnabled;
  
  MigrationConfig({
    required this.phase,
    required this.pubSubPercentage,
    required this.dualPublish,
    required this.metricsEnabled,
    required this.fallbackEnabled,
    required this.batchingEnabled,
  });
  
  factory MigrationConfig.fromJson(Map<String, dynamic> json) {
    return MigrationConfig(
      phase: json['phase'] ?? PHASE_TESTING,
      pubSubPercentage: json['pubSubPercentage'] ?? 0,
      dualPublish: json['dualPublish'] ?? true,
      metricsEnabled: json['metricsEnabled'] ?? true,
      fallbackEnabled: json['fallbackEnabled'] ?? true,
      batchingEnabled: json['batchingEnabled'] ?? false,
    );
  }
  
  bool shouldUsePubSub(String deviceId) {
    // Consistent hashing for gradual rollout
    final hash = deviceId.hashCode.abs();
    final bucket = hash % 100;
    return bucket < pubSubPercentage;
  }
}
```

### 6.2 Migration Timeline

| Week | Phase | Description | Success Criteria |
|------|-------|-------------|------------------|
| 1-2 | Development | Implement Pub/Sub client | All tests passing |
| 3-4 | Testing | Internal testing | 99% delivery rate |
| 5-6 | Canary (1%) | Limited rollout | No increase in errors |
| 7-8 | Rollout (10%) | Expand to 10% | Latency < 100ms |
| 9-10 | Rollout (50%) | Half of users | Battery usage reduced |
| 11-12 | Complete (100%) | Full migration | MQTT deprecated |

### 6.3 Rollback Strategy

```dart
// lib/services/rollback_manager.dart
class RollbackManager {
  static const String ROLLBACK_FLAG = 'emergency-rollback-to-mqtt';
  
  Future<bool> shouldRollback() async {
    // Check multiple signals
    final remoteKillSwitch = await _checkRemoteKillSwitch();
    final errorThresholdExceeded = await _checkErrorThreshold();
    final performanceDegraded = await _checkPerformance();
    
    return remoteKillSwitch || errorThresholdExceeded || performanceDegraded;
  }
  
  Future<bool> _checkRemoteKillSwitch() async {
    return await _ldClient.boolVariation(ROLLBACK_FLAG, false);
  }
  
  Future<bool> _checkErrorThreshold() async {
    final recentErrors = await _getRecentErrorCount();
    final totalRequests = await _getTotalRequestCount();
    
    if (totalRequests == 0) return false;
    
    final errorRate = recentErrors / totalRequests;
    return errorRate > 0.05; // 5% error threshold
  }
  
  Future<bool> _checkPerformance() async {
    final avgLatency = await _getAverageLatency();
    return avgLatency > 500; // 500ms threshold
  }
}
```

## 7. Testing Strategy

### 7.1 Unit Tests

```dart
// test/services/location_tracker_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:geolocator/geolocator.dart';

@GenerateMocks([PubsubApi, MqttServerClient, LDClient])
void main() {
  group('LocationTrackerV2', () {
    late LocationTrackerV2 tracker;
    late MockPubsubApi mockPubsubApi;
    late MockMqttServerClient mockMqttClient;
    late MockLDClient mockLDClient;
    
    setUp(() {
      mockPubsubApi = MockPubsubApi();
      mockMqttClient = MockMqttServerClient();
      mockLDClient = MockLDClient();
      
      tracker = LocationTrackerV2(
        projectId: 'test-project',
        deviceId: 'test-device-123',
      );
    });
    
    test('should format location update correctly', () async {
      // Arrange
      final position = Position(
        latitude: 1.3521,
        longitude: 103.8198,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 10.0,
        heading: 180.0,
        speed: 10.0, // m/s
        speedAccuracy: 1.0,
      );
      
      // Act
      final update = tracker.createLocationUpdate(position);
      
      // Assert
      expect(update.deviceId, equals('test-device-123'));
      expect(update.latitude, equals(1.3521));
      expect(update.longitude, equals(103.8198));
      expect(update.speed, equals(36.0)); // 10 m/s = 36 km/h
      expect(update.accuracy, equals(5.0));
      expect(update.bearing, equals(180.0));
    });
    
    test('should queue updates when offline', () async {
      // Arrange
      when(mockConnectivity.checkConnectivity())
          .thenAnswer((_) async => ConnectivityResult.none);
      
      final position = createTestPosition();
      
      // Act
      await tracker.handleLocationUpdate(position);
      
      // Assert
      verify(mockOfflineQueue.put(any, any)).called(1);
      verifyNever(mockPubsubApi.projects.topics.publish(any, any));
    });
    
    test('should process offline queue when back online', () async {
      // Arrange
      final queuedUpdates = List.generate(
        5,
        (i) => createTestLocationUpdate(index: i),
      );
      
      when(mockOfflineQueue.values).thenReturn(
        queuedUpdates.map((u) => jsonEncode(u.toJson())).toList(),
      );
      
      // Act
      await tracker.processOfflineQueue();
      
      // Assert
      verify(mockPubsubApi.projects.topics.publish(any, any)).called(5);
      verify(mockOfflineQueue.clear()).called(1);
    });
  });
  
  group('DualPublisher', () {
    test('should publish to both MQTT and Pub/Sub during migration', () async {
      // Arrange
      when(mockLDClient.boolVariation('use-pubsub-primary', false))
          .thenAnswer((_) async => false);
      when(mockLDClient.boolVariation('test-pubsub', false))
          .thenAnswer((_) async => true);
      
      final update = createTestLocationUpdate();
      
      // Act
      await dualPublisher.publishLocation(update);
      
      // Assert
      verify(mockMqttClient.publishMessage(any, any, any)).called(1);
      verify(mockPubsubApi.projects.topics.publish(any, any)).called(1);
    });
    
    test('should fallback to MQTT on Pub/Sub failure', () async {
      // Arrange
      when(mockLDClient.boolVariation('use-pubsub-primary', false))
          .thenAnswer((_) async => true);
      when(mockPubsubApi.projects.topics.publish(any, any))
          .thenThrow(Exception('Network error'));
      
      final update = createTestLocationUpdate();
      
      // Act
      await dualPublisher.publishLocation(update);
      
      // Assert
      verify(mockMqttClient.publishMessage(any, any, any)).called(1);
    });
  });
}
```

### 7.2 Integration Tests

```dart
// integration_test/location_tracking_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  
  group('Location Tracking Integration', () {
    testWidgets('should send location via Pub/Sub', (tester) async {
      // Start app
      await tester.pumpWidget(MyApp());
      await tester.pumpAndSettle();
      
      // Grant location permission
      await _grantLocationPermission();
      
      // Start tracking
      await tester.tap(find.byKey(Key('startTrackingButton')));
      await tester.pumpAndSettle();
      
      // Wait for location update
      await tester.pump(Duration(seconds: 5));
      
      // Verify location was sent
      final statusText = find.text('Location sent via Pub/Sub');
      expect(statusText, findsOneWidget);
      
      // Verify in backend
      final response = await _checkBackendReceived();
      expect(response['source'], equals('pubsub'));
      expect(response['deviceId'], isNotEmpty);
    });
    
    testWidgets('should handle Pub/Sub failure gracefully', (tester) async {
      // Simulate Pub/Sub failure
      await _simulatePubSubFailure(true);
      
      await tester.pumpWidget(MyApp());
      await tester.pumpAndSettle();
      
      // Start tracking
      await tester.tap(find.byKey(Key('startTrackingButton')));
      await tester.pump(Duration(seconds: 5));
      
      // Should fallback to MQTT
      final statusText = find.text('Location sent via MQTT (fallback)');
      expect(statusText, findsOneWidget);
      
      // Cleanup
      await _simulatePubSubFailure(false);
    });
    
    testWidgets('should batch locations on cellular network', (tester) async {
      // Simulate cellular network
      await _simulateNetworkType('cellular');
      
      await tester.pumpWidget(MyApp());
      await tester.pumpAndSettle();
      
      // Send multiple locations
      for (int i = 0; i < 5; i++) {
        await _triggerLocationUpdate();
        await tester.pump(Duration(seconds: 1));
      }
      
      // Verify batching
      final pendingCount = find.text('5 locations pending');
      expect(pendingCount, findsOneWidget);
      
      // Wait for batch timer
      await tester.pump(Duration(seconds: 30));
      
      // Verify batch sent
      final sentText = find.text('Batch of 5 locations sent');
      expect(sentText, findsOneWidget);
    });
  });
}

Future<void> _grantLocationPermission() async {
  // Platform-specific permission granting
  if (Platform.isAndroid) {
    await Geolocator.requestPermission();
  } else if (Platform.isIOS) {
    await Geolocator.requestPermission();
  }
}

Future<Map<String, dynamic>> _checkBackendReceived() async {
  final response = await http.get(
    Uri.parse('https://api.innovd.com/test/last-location'),
  );
  return jsonDecode(response.body);
}
```

### 7.3 Performance Testing

```dart
// test/performance/location_tracking_perf_test.dart
import 'dart:io';
import 'package:flutter_driver/flutter_driver.dart';
import 'package:test/test.dart';

void main() {
  group('Location Tracking Performance', () {
    late FlutterDriver driver;
    
    setUpAll(() async {
      driver = await FlutterDriver.connect();
    });
    
    tearDownAll(() async {
      await driver.close();
    });
    
    test('measure battery impact', () async {
      // Get initial battery level
      final initialBattery = await driver.requestData('getBatteryLevel');
      
      // Start location tracking
      await driver.tap(find.byValueKey('startTrackingButton'));
      
      // Run for 30 minutes
      await Future.delayed(Duration(minutes: 30));
      
      // Get final battery level
      final finalBattery = await driver.requestData('getBatteryLevel');
      
      // Calculate drain
      final batteryDrain = double.parse(initialBattery) - double.parse(finalBattery);
      
      // Should be less than 5% in 30 minutes
      expect(batteryDrain, lessThan(5.0));
      
      // Get performance metrics
      final metrics = await driver.requestData('getPerformanceMetrics');
      final perfData = jsonDecode(metrics);
      
      // Verify performance targets
      expect(perfData['avgCpuUsage'], lessThan(10.0)); // < 10% CPU
      expect(perfData['avgMemoryUsage'], lessThan(50)); // < 50MB
      expect(perfData['avgNetworkLatency'], lessThan(100)); // < 100ms
    });
    
    test('stress test with high frequency updates', () async {
      // Configure high frequency mode
      await driver.requestData('setHighFrequencyMode');
      
      // Start tracking
      await driver.tap(find.byValueKey('startTrackingButton'));
      
      // Monitor for 10 minutes
      final startTime = DateTime.now();
      int updateCount = 0;
      
      while (DateTime.now().difference(startTime).inMinutes < 10) {
        final status = await driver.requestData('getTrackingStatus');
        final statusData = jsonDecode(status);
        updateCount = statusData['totalUpdates'];
        
        // Should maintain performance
        expect(statusData['droppedUpdates'], equals(0));
        expect(statusData['failedUpdates'], lessThan(updateCount * 0.01)); // < 1% failure
        
        await Future.delayed(Duration(seconds: 30));
      }
      
      // Should handle at least 600 updates (1 per second)
      expect(updateCount, greaterThan(600));
    });
  });
}

## 8. Rollout Plan

### 8.1 Phased Rollout Strategy

#### Phase 1: Development Testing (Week 1-2)
- Deploy to internal test devices
- Monitor performance and reliability
- Fix any critical issues

#### Phase 2: Beta Testing (Week 3-4)
- 1% of users with Pub/Sub enabled
- A/B testing metrics collection
- Fallback to MQTT enabled

#### Phase 3: Gradual Rollout (Week 5-8)
```javascript
// Remote config for rollout
{
  "location_tracking": {
    "pubsub_rollout": {
      "week_5": { "percentage": 10, "regions": ["SG"] },
      "week_6": { "percentage": 25, "regions": ["SG", "MY"] },
      "week_7": { "percentage": 50, "regions": ["ALL"] },
      "week_8": { "percentage": 100, "regions": ["ALL"] }
    }
  }
}
```

### 8.2 Monitoring Metrics

```typescript
// Metrics to track during rollout
interface RolloutMetrics {
  // Reliability
  deliverySuccessRate: number;      // Target: >99.9%
  messageLatency: number;           // Target: <100ms
  fallbackRate: number;             // Target: <1%
  
  // Performance
  batteryUsageChange: number;       // Target: -20%
  dataUsageChange: number;          // Target: -30%
  cpuUsageChange: number;          // Target: -15%
  
  // User Impact
  crashRate: number;                // Target: <0.1%
  userComplaints: number;           // Target: 0
  locationAccuracy: number;         // Target: No degradation
}
```

## 9. Monitoring & Debugging

### 9.1 Client-Side Logging

```swift
// iOS Debug Logger
class LocationDebugLogger {
    static func logLocationUpdate(_ update: LocationUpdate, method: String) {
        #if DEBUG
        print("""
        📍 Location Update:
        - Method: \(method)
        - Device: \(update.deviceId)
        - Coords: \(update.coordinates.latitude), \(update.coordinates.longitude)
        - Accuracy: \(update.accuracy)m
        - Battery: \(update.batteryLevel * 100)%
        - Network: \(update.networkType)
        """)
        #endif
    }
    
    static func logError(_ error: Error, context: String) {
        // Send to crash reporting
        Crashlytics.crashlytics().record(error: error)
        
        // Log locally
        print("❌ Location Error [\(context)]: \(error)")
    }
}
```

### 9.2 Backend Monitoring

```yaml
# Stackdriver metrics for Pub/Sub
resource:
  type: pubsub_topic
  labels:
    topic_id: location-updates

metrics:
  - name: publish_message_count
    threshold: < 1000/min  # Alert if drops below
    
  - name: publish_request_latencies
    threshold: > 200ms     # Alert if exceeds
    
  - name: unacked_messages
    threshold: > 1000      # Alert if builds up
```

### 9.3 Debug Dashboard

```typescript
// Debug UI Component
const LocationDebugPanel = () => {
  const [stats, setStats] = useState({
    sentViaPubSub: 0,
    sentViaMQTT: 0,
    failedAttempts: 0,
    pendingUpdates: 0,
    lastError: null
  });
  
  return (
    <View style={styles.debugPanel}>
      <Text>Pub/Sub: {stats.sentViaPubSub}</Text>
      <Text>MQTT (Fallback): {stats.sentViaMQTT}</Text>
      <Text>Failed: {stats.failedAttempts}</Text>
      <Text>Pending: {stats.pendingUpdates}</Text>
      {stats.lastError && (
        <Text style={styles.error}>Error: {stats.lastError}</Text>
      )}
    </View>
  );
};
```

## 10. FAQ & Troubleshooting

### Common Issues

#### Q: Location updates not being received
```typescript
// Diagnostic steps
async function diagnoseLocationIssues() {
  // 1. Check permissions
  const hasPermission = await checkLocationPermission();
  console.log('Location permission:', hasPermission);
  
  // 2. Check Pub/Sub connectivity
  const canConnect = await testPubSubConnection();
  console.log('Pub/Sub connection:', canConnect);
  
  // 3. Check pending queue
  const pending = await getPendingUpdates();
  console.log('Pending updates:', pending.length);
  
  // 4. Check feature flags
  const flags = await getFeatureFlags();
  console.log('Feature flags:', flags);
}
```

#### Q: High battery consumption
```swift
// Optimize location updates
locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
locationManager.distanceFilter = 50 // Only update if moved 50m
locationManager.activityType = .automotiveNavigation
locationManager.pausesLocationUpdatesAutomatically = true
```

#### Q: Messages being delivered multiple times
```kotlin
// Implement idempotency
class LocationDeduplicator {
    private val recentMessages = LRUCache<String, Long>(1000)
    
    fun isDuplicate(update: LocationUpdate): Boolean {
        val key = "${update.deviceId}-${update.timestamp}"
        val existing = recentMessages.get(key)
        
        if (existing != null) {
            return true
        }
        
        recentMessages.put(key, System.currentTimeMillis())
        return false
    }
}
```

### Migration Checklist

- [ ] Update mobile app dependencies
- [ ] Implement Pub/Sub client
- [ ] Add fallback mechanism
- [ ] Update offline queue
- [ ] Add monitoring/logging
- [ ] Test on all OS versions
- [ ] Update privacy policy
- [ ] Train support team
- [ ] Monitor rollout metrics
- [ ] Remove MQTT code (final phase)

## Conclusion

This migration guide provides a comprehensive approach to transitioning from MQTT to Google Pub/Sub for location tracking. The key success factors are:

1. **Gradual rollout** with feature flags
2. **Fallback mechanism** to ensure reliability
3. **Comprehensive monitoring** to catch issues early
4. **Offline support** for poor connectivity
5. **Thorough testing** at each phase

Following this guide will ensure a smooth transition with minimal user impact while gaining the benefits of a more scalable and reliable infrastructure.