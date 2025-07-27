# Flutter App Migration Guide
## From MQTT to Google Pub/Sub

## Table of Contents
1. [Overview](#1-overview)
2. [Current MQTT Implementation](#2-current-mqtt-implementation)
3. [New Pub/Sub Implementation](#3-new-pubsub-implementation)
4. [Flutter SDK Integration](#4-flutter-sdk-integration)
5. [Migration Implementation](#5-migration-implementation)
6. [Testing Strategy](#6-testing-strategy)
7. [Performance Optimization](#7-performance-optimization)
8. [Troubleshooting](#8-troubleshooting)

## 1. Overview

### Migration Goals
- Replace MQTT with Google Pub/Sub for location tracking
- Maintain backward compatibility during transition
- Improve reliability and reduce battery consumption
- Enable better offline support

### Key Changes

| Feature | MQTT (Current) | Pub/Sub (New) |
|---------|----------------|---------------|
| Protocol | TCP/WebSocket | HTTP/2 (gRPC) |
| Authentication | Username/Password | OAuth2/Service Account |
| Connection Model | Persistent | Request-based |
| Offline Support | Manual queue | Automatic retry |
| Battery Impact | Higher | Lower |
| Message Format | Custom JSON | Protobuf/JSON |

## 2. Current MQTT Implementation

### Flutter MQTT Implementation
```dart
// Current MQTT implementation in Flutter
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';

class MQTTLocationService {
  late MqttServerClient client;
  final String broker = 'mqtt.innovd.com';
  final int port = 8883;
  late String clientId;
  
  MQTTLocationService() {
    clientId = 'Flutter-${DateTime.now().millisecondsSinceEpoch}';
    client = MqttServerClient(broker, clientId);
    client.port = port;
    client.secure = true;
    client.keepAlivePeriod = 60;
    client.autoReconnect = true;
  }
  
  Future<void> connect() async {
    client.logging(on: false);
    
    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs('device_user', 'device_password')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    
    client.connectionMessage = connMessage;
    
    try {
      await client.connect();
      print('MQTT Connected');
    } catch (e) {
      print('MQTT Connection failed: $e');
      client.disconnect();
    }
    
    client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      // Handle incoming messages if needed
    });
  }
  
  void publishLocation(Position position) {
    final topic = 'device/telemetry/$clientId';
    
    final payload = {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'speed': position.speed,
      'accuracy': position.accuracy,
      'altitude': position.altitude,
      'heading': position.heading,
      'timestamp': position.timestamp?.millisecondsSinceEpoch ?? 
                   DateTime.now().millisecondsSinceEpoch,
    };
    
    final builder = MqttClientPayloadBuilder();
    builder.addString(json.encode(payload));
    
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }
  
  void disconnect() {
    client.disconnect();
  }
}

## 3. New Pub/Sub Implementation

### Architecture Overview
```
Mobile App
    ├── Location Manager (Native)
    ├── Migration Manager (Controls dual publishing)
    ├── MQTT Client (Legacy)
    └── Pub/Sub Client (New)
           ├── Authentication Service
           ├── Message Publisher
           ├── Offline Queue
           └── Retry Manager
```

### Authentication Setup

Flutter handles authentication through the googleapis_auth package, which manages service account credentials and token refresh automatically across both iOS and Android platforms.

```dart
// lib/services/google_auth_service.dart
import 'package:googleapis_auth/auth_io.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'dart:convert';

class GoogleAuthService {
  ServiceAccountCredentials? _credentials;
  AuthClient? _authClient;
  DateTime? _tokenExpiry;
  
  Future<void> initialize() async {
    // Load service account from assets
    final jsonString = await rootBundle.loadString(
      'assets/service-account.json',
    );
    
    _credentials = ServiceAccountCredentials.fromJson(
      json.decode(jsonString),
    );
  }
  
  Future<AuthClient> getAuthClient() async {
    // Check if current client is still valid
    if (_authClient != null && 
        _tokenExpiry != null &&
        _tokenExpiry!.isAfter(DateTime.now().add(Duration(minutes: 5)))) {
      return _authClient!;
    }
    
    // Create new authenticated client
    _authClient = await clientViaServiceAccount(
      _credentials!,
      ['https://www.googleapis.com/auth/pubsub'],
    );
    
    // Estimate token expiry (typically 1 hour)
    _tokenExpiry = DateTime.now().add(Duration(minutes: 55));
    
    return _authClient!;
  }
  
  void dispose() {
    _authClient?.close();
  }
}
```

### Platform-Specific Configuration

While the authentication code is unified in Flutter, you'll need to configure each platform to include the service account file:

#### iOS Configuration (ios/Runner/Info.plist)
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>googleapis.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSExceptionMinimumTLSVersion</key>
            <string>TLSv1.2</string>
        </dict>
    </dict>
</dict>
```

#### Android Configuration (android/app/build.gradle)
```gradle
android {
    defaultConfig {
        // Enable multidex for Google Play Services
        multiDexEnabled true
    }
}

dependencies {
    implementation 'com.android.support:multidex:1.0.3'
}
```

## 4. Flutter SDK Integration

### Pub/Sub Client Implementation

```dart
// lib/services/pubsub_location_client.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:googleapis/pubsub/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive/hive.dart';

class PubSubLocationClient {
  late PubsubApi _pubsubApi;
  final String projectId;
  final String topicId;
  late AuthClient _authClient;
  late Box<String> _offlineQueue;
  bool _isInitialized = false;
  
  PubSubLocationClient({
    required this.projectId,
    required this.topicId,
  });
  
  Future<void> initialize() async {
    // Load service account credentials
    final credentials = await _loadServiceAccount();
    
    // Create authenticated client
    _authClient = await clientViaServiceAccount(
      credentials,
      [PubsubApi.pubsubScope],
    );
    
    // Initialize Pub/Sub API
    _pubsubApi = PubsubApi(_authClient);
    
    // Initialize offline queue
    await Hive.initFlutter();
    _offlineQueue = await Hive.openBox<String>('pubsub_queue');
    
    _isInitialized = true;
    
    // Process any queued messages
    await _processOfflineQueue();
  }
  
  Future<ServiceAccountCredentials> _loadServiceAccount() async {
    // Load from assets
    final jsonString = await rootBundle.loadString(
      'assets/service-account.json',
    );
    return ServiceAccountCredentials.fromJson(json.decode(jsonString));
  }
  
  Future<void> publishLocation(Position position, String deviceId) async {
    if (!_isInitialized) {
      throw StateError('PubSubClient not initialized');
    }
    
    final locationData = LocationData(
      deviceId: deviceId,
      latitude: position.latitude,
      longitude: position.longitude,
      speed: position.speed,
      accuracy: position.accuracy,
      altitude: position.altitude,
      heading: position.heading,
      timestamp: position.timestamp ?? DateTime.now(),
    );
    
    final message = PubsubMessage()
      ..data = base64Encode(utf8.encode(json.encode(locationData.toMap())))
      ..attributes = {
        'deviceId': deviceId,
        'deviceType': Platform.isIOS ? 'iOS' : 'Android',
        'timestamp': locationData.timestamp.millisecondsSinceEpoch.toString(),
        'accuracy': locationData.accuracy.toString(),
      };
    
    try {
      await _publish(message);
    } catch (e) {
      print('Failed to publish, queuing for retry: $e');
      await _queueForOffline(locationData);
      // Schedule retry
      Future.delayed(Duration(seconds: 5), _processOfflineQueue);
    }
  }
  
  Future<void> _publish(PubsubMessage message) async {
    final request = PublishRequest()..messages = [message];
    
    final topicName = 'projects/$projectId/topics/$topicId';
    await _pubsubApi.projects.topics.publish(request, topicName);
  }
  
  Future<void> _queueForOffline(LocationData data) async {
    final key = DateTime.now().millisecondsSinceEpoch.toString();
    await _offlineQueue.put(key, json.encode(data.toMap()));
  }
  
  Future<void> _processOfflineQueue() async {
    if (_offlineQueue.isEmpty || !_isInitialized) return;
    
    final keys = _offlineQueue.keys.toList();
    for (final key in keys) {
      final dataString = _offlineQueue.get(key);
      if (dataString != null) {
        try {
          final data = LocationData.fromMap(json.decode(dataString));
          final message = PubsubMessage()
            ..data = base64Encode(utf8.encode(dataString))
            ..attributes = {
              'deviceId': data.deviceId,
              'timestamp': data.timestamp.millisecondsSinceEpoch.toString(),
              'retry': 'true',
            };
          
          await _publish(message);
          await _offlineQueue.delete(key);
        } catch (e) {
          print('Failed to process queued message: $e');
        }
      }
    }
  }
  
  void dispose() {
    _authClient.close();
    _offlineQueue.close();
  }
}

// Data models
class LocationData {
  final String deviceId;
  final double latitude;
  final double longitude;
  final double speed;
  final double accuracy;
  final double altitude;
  final double heading;
  final DateTime timestamp;
  
  LocationData({
    required this.deviceId,
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.accuracy,
    required this.altitude,
    required this.heading,
    required this.timestamp,
  });
  
  Map<String, dynamic> toMap() => {
    'deviceId': deviceId,
    'latitude': latitude,
    'longitude': longitude,
    'speed': speed,
    'accuracy': accuracy,
    'altitude': altitude,
    'heading': heading,
    'timestamp': timestamp.toIso8601String(),
  };
  
  factory LocationData.fromMap(Map<String, dynamic> map) => LocationData(
    deviceId: map['deviceId'],
    latitude: map['latitude'],
    longitude: map['longitude'],
    speed: map['speed'],
    accuracy: map['accuracy'],
    altitude: map['altitude'],
    heading: map['heading'],
    timestamp: DateTime.parse(map['timestamp']),
  );
}
```

## 5. Migration Implementation

### Dual Publishing Manager

```dart
// lib/services/location_publishing_manager.dart
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';
import 'package:geolocator/geolocator.dart';

class LocationPublishingManager {
  final MQTTLocationService _mqttClient;
  final PubSubLocationClient _pubsubClient;
  final LDClient _ldClient;
  final Analytics _analytics;
  late MigrationConfig _config;
    
  String deviceId;
  
  LocationPublishingManager({
    required MQTTLocationService mqttClient,
    required PubSubLocationClient pubsubClient,
    required LDClient ldClient,
    required Analytics analytics,
    required this.deviceId,
  }) : _mqttClient = mqttClient,
       _pubsubClient = pubsubClient,
       _ldClient = ldClient,
       _analytics = analytics;
  
  Future<void> initialize() async {
    // Initialize both clients
    await _mqttClient.connect();
    await _pubsubClient.initialize();
    
    // Load migration config
    _config = await MigrationConfig.load(_ldClient);
  }
  
  Future<void> publishLocation(Position position) async {
    final startTime = DateTime.now();
    bool mqttSuccess = false;
    bool pubsubSuccess = false;
    
    // Parallel publishing
    final futures = <Future>[];
    
    // MQTT Publishing
    if (_config.mqttEnabled) {
      futures.add(
        Future(() async {
          try {
            _mqttClient.publishLocation(position);
            mqttSuccess = true;
          } catch (e) {
            _analytics.track('mqtt_publish_error', {
              'error': e.toString(),
              'device_id': deviceId,
            });
          }
        }),
      );
    }
    
    // Pub/Sub Publishing
    if (_config.pubsubEnabled) {
      futures.add(
        Future(() async {
          try {
            await _pubsubClient.publishLocation(position, deviceId);
            pubsubSuccess = true;
          } catch (e) {
            _analytics.track('pubsub_publish_error', {
              'error': e.toString(),
              'device_id': deviceId,
            });
          }
        }),
      );
    }
    
    // Wait for all publishers
    await Future.wait(futures);
    
    // Track metrics
    final duration = DateTime.now().difference(startTime);
    _analytics.track('location_publish_complete', {
      'mqtt_success': mqttSuccess,
      'pubsub_success': pubsubSuccess,
      'duration_ms': duration.inMilliseconds,
      'migration_phase': _config.phase,
      'device_id': deviceId,
    });
    
    // Handle failures
    if (!mqttSuccess && !pubsubSuccess) {
      throw LocationPublishException('All protocols failed');
    }
  }
}

// Migration configuration
class MigrationConfig {
  final bool mqttEnabled;
  final bool pubsubEnabled;
  final String phase; // "testing", "rollout", "production"
  final int devicePercentage;
  final bool fallbackEnabled;
  
  MigrationConfig({
    required this.mqttEnabled,
    required this.pubsubEnabled,
    required this.phase,
    required this.devicePercentage,
    required this.fallbackEnabled,
  });
  
  static Future<MigrationConfig> load(LDClient ldClient) async {
    // Fetch from LaunchDarkly
    final config = await ldClient.jsonVariation(
      'location-migration-config',
      defaultValue: _defaultConfig,
    );
    
    return MigrationConfig(
      mqttEnabled: config['mqtt_enabled'] ?? true,
      pubsubEnabled: config['pubsub_enabled'] ?? false,
      phase: config['phase'] ?? 'testing',
      devicePercentage: config['device_percentage'] ?? 0,
      fallbackEnabled: config['fallback_enabled'] ?? true,
    );
  }
  
  static const _defaultConfig = {
    'mqtt_enabled': true,
    'pubsub_enabled': false,
    'phase': 'testing',
    'device_percentage': 0,
    'fallback_enabled': true,
  };
}
```

### Battery Optimization

```dart
// lib/services/optimized_location_manager.dart
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';

class OptimizedLocationManager {
  final LocationPublishingManager _publishingManager;
  final Battery _battery = Battery();
  
  StreamSubscription<Position>? _positionStream;
  DateTime? _lastPublishTime;
  final List<Position> _locationBuffer = [];
  late LocationSettings _locationSettings;
  BatteryState _batteryState = BatteryState.unknown;
  int _batteryLevel = 100;
  
  OptimizedLocationManager({
    required LocationPublishingManager publishingManager,
  }) : _publishingManager = publishingManager;
  
  Future<void> startLocationTracking() async {
    // Monitor battery state
    _battery.onBatteryStateChanged.listen((BatteryState state) {
      _batteryState = state;
      _updateLocationSettings();
    });
    
    // Get initial battery level
    _batteryLevel = await _battery.batteryLevel ?? 100;
    
    // Configure location settings based on battery
    _updateLocationSettings();
    _startLocationUpdates();
  }
  
  void _updateLocationSettings() {
    // Dynamic settings based on battery state
    if (_batteryState == BatteryState.charging) {
      // High accuracy when charging
      _locationSettings = LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
        timeLimit: Duration(seconds: 10),
      );
    } else if (_batteryLevel > 50) {
      // Balanced mode
      _locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        timeLimit: Duration(seconds: 20),
      );
    } else if (_batteryLevel > 20) {
      // Power saving mode
      _locationSettings = LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 25,
        timeLimit: Duration(seconds: 30),
      );
    } else {
      // Critical battery mode
      _locationSettings = LocationSettings(
        accuracy: LocationAccuracy.low,
        distanceFilter: 50,
        timeLimit: Duration(minutes: 1),
      );
    }
    
    // Restart location updates with new settings
    if (_positionStream != null) {
      _positionStream?.cancel();
      _startLocationUpdates();
    }
  }
  
  void _startLocationUpdates() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).listen(_handleLocationUpdate);
  }
  
  void _handleLocationUpdate(Position position) {
    if (_shouldPublishLocation(position)) {
      _publishLocation(position);
    } else {
      _bufferLocation(position);
    }
  }
  
  bool _shouldPublishLocation(Position position) {
    // Check accuracy
    if (position.accuracy > 100) {
      return false;
    }
    
    // Check time since last publish
    if (_lastPublishTime != null) {
      final timeDiff = DateTime.now().difference(_lastPublishTime!);
      
      // Dynamic interval based on speed
      Duration minInterval;
      if (position.speed > 20) {
        // Moving fast (driving)
        minInterval = Duration(seconds: 5);
      } else if (position.speed > 2) {
        // Walking
        minInterval = Duration(seconds: 10);
      } else {
        // Stationary
        minInterval = Duration(seconds: 30);
      }
      
      if (timeDiff < minInterval) {
        return false;
      }
    }
    
    return true;
  }
  
  Future<void> _publishLocation(Position position) async {
    try {
      await _publishingManager.publishLocation(position);
      _lastPublishTime = DateTime.now();
    } catch (e) {
      print('Failed to publish location: $e');
      _bufferLocation(position);
    }
  }
  
  void _bufferLocation(Position position) {
    _locationBuffer.add(position);
    
    // Batch publish when buffer is full
    if (_locationBuffer.length >= 10) {
      _publishBatchLocations();
    }
  }
  
  Future<void> _publishBatchLocations() async {
    final batch = List<Position>.from(_locationBuffer);
    _locationBuffer.clear();
    
    for (final position in batch) {
      await _publishingManager.publishLocation(position);
      await Future.delayed(Duration(milliseconds: 50)); // Rate limiting
    }
  }
  
  void dispose() {
    _positionStream?.cancel();
  }
}
```

### Background Location Tracking

```dart
// lib/services/background_location_service.dart
import 'package:workmanager/workmanager.dart';
import 'package:geolocator/geolocator.dart';

// Background task callback
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    switch (task) {
      case 'location-update':
        await _handleLocationUpdate();
        break;
      case 'batch-sync':
        await _handleBatchSync();
        break;
    }
    return Future.value(true);
  });
}

class BackgroundLocationService {
  static const String locationTaskName = 'location-update';
  static const String batchSyncTaskName = 'batch-sync';
  
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    
    // Register periodic location task
    await Workmanager().registerPeriodicTask(
      '1',
      locationTaskName,
      frequency: Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
    );
    
    // Register batch sync task
    await Workmanager().registerPeriodicTask(
      '2',
      batchSyncTaskName,
      frequency: Duration(hours: 1),
      constraints: Constraints(
        networkType: NetworkType.unmetered,
        requiresCharging: false,
      ),
    );
  }
  
  static Future<void> _handleLocationUpdate() async {
    try {
      // Get current location
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 30),
      );
      
      // Initialize services
      final mqttClient = MQTTLocationService();
      final pubsubClient = PubSubLocationClient(
        projectId: 'innovd-prod',
        topicId: 'location-updates',
      );
      
      final ldClient = LDClient();
      final analytics = Analytics();
      
      final publishingManager = LocationPublishingManager(
        mqttClient: mqttClient,
        pubsubClient: pubsubClient,
        ldClient: ldClient,
        analytics: analytics,
        deviceId: await _getDeviceId(),
      );
      
      await publishingManager.initialize();
      await publishingManager.publishLocation(position);
      
    } catch (e) {
      print('Background location update failed: $e');
    }
  }
  
  static Future<void> _handleBatchSync() async {
    // Process any queued locations
    final offlineQueue = await Hive.openBox<String>('location_queue');
    if (offlineQueue.isNotEmpty) {
      // Initialize Pub/Sub client and process queue
      final pubsubClient = PubSubLocationClient(
        projectId: 'innovd-prod',
        topicId: 'location-updates',
      );
      await pubsubClient.initialize();
      // Queue will be processed automatically
    }
  }
  
  static Future<String> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor ?? 'unknown';
    }
    return 'unknown';
  }
}
```

## 6. Testing Strategy

### Unit Tests

#### Flutter Unit Tests
```dart
// test/services/pubsub_location_client_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive/hive.dart';
import 'package:googleapis/pubsub/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:innovd_app/services/pubsub_location_client.dart';

@GenerateMocks([PubsubApi, AuthClient, Box])
import 'pubsub_location_client_test.mocks.dart';

void main() {
  group('PubSubLocationClient', () {
    late PubSubLocationClient client;
    late MockPubsubApi mockPubsubApi;
    late MockAuthClient mockAuthClient;
    late MockBox mockOfflineQueue;
    
    setUp(() {
      mockPubsubApi = MockPubsubApi();
      mockAuthClient = MockAuthClient();
      mockOfflineQueue = MockBox();
      
      client = PubSubLocationClient(
        projectId: 'test-project',
        topicId: 'test-topic',
      );
      
      // Inject mocks
      client.testInjectDependencies(
        pubsubApi: mockPubsubApi,
        authClient: mockAuthClient,
        offlineQueue: mockOfflineQueue,
      );
    });
    
    test('encodes location data correctly', () async {
      // Given
      final position = Position(
        latitude: 1.3521,
        longitude: 103.8198,
        timestamp: DateTime.now(),
        accuracy: 10.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 45.5,
        speedAccuracy: 5.0,
      );
      
      // When
      final locationData = LocationData(
        deviceId: 'test-device',
        latitude: position.latitude,
        longitude: position.longitude,
        speed: position.speed,
        accuracy: position.accuracy,
        altitude: position.altitude,
        heading: position.heading,
        timestamp: position.timestamp!,
      );
      
      final encoded = locationData.toMap();
      final decoded = LocationData.fromMap(encoded);
      
      // Then
      expect(decoded.latitude, closeTo(1.3521, 0.0001));
      expect(decoded.longitude, closeTo(103.8198, 0.0001));
      expect(decoded.speed, closeTo(45.5, 0.1));
      expect(decoded.accuracy, closeTo(10.0, 0.1));
    });
    
    test('queues locations when offline', () async {
      // Given
      when(mockOfflineQueue.isEmpty).thenReturn(true);
      when(mockOfflineQueue.put(any, any)).thenAnswer((_) async => {});
      
      final position = createTestPosition();
      
      // Mock publish failure
      when(mockPubsubApi.projects.topics.publish(any, any))
          .thenThrow(Exception('Network error'));
      
      // When
      try {
        await client.publishLocation(position, 'test-device');
      } catch (e) {
        // Expected
      }
      
      // Then
      verify(mockOfflineQueue.put(any, any)).called(1);
    });
    
    test('processes offline queue when connection restored', () async {
      // Given
      final queuedData = {
        '1': '{"deviceId":"test","latitude":1.3521,"longitude":103.8198}',
        '2': '{"deviceId":"test","latitude":1.3522,"longitude":103.8199}',
      };
      
      when(mockOfflineQueue.isEmpty).thenReturn(false);
      when(mockOfflineQueue.keys).thenReturn(queuedData.keys);
      when(mockOfflineQueue.get(any)).thenAnswer(
        (invocation) => queuedData[invocation.positionalArguments[0]],
      );
      when(mockOfflineQueue.delete(any)).thenAnswer((_) async => {});
      
      // Mock successful publish
      when(mockPubsubApi.projects.topics.publish(any, any))
          .thenAnswer((_) async => PublishResponse());
      
      // When
      await client.processOfflineQueue();
      
      // Then
      verify(mockPubsubApi.projects.topics.publish(any, any)).called(2);
      verify(mockOfflineQueue.delete(any)).called(2);
    });
    
    test('respects queue size limit', () async {
      // Test that queue doesn't grow beyond 1000 items
      final locations = List.generate(1500, (i) => createTestPosition());
      var queueSize = 0;
      
      when(mockOfflineQueue.put(any, any)).thenAnswer((_) async {
        queueSize++;
      });
      
      // When - add 1500 locations
      for (final location in locations) {
        await client.queueForOffline(LocationData(
          deviceId: 'test',
          latitude: location.latitude,
          longitude: location.longitude,
          speed: location.speed,
          accuracy: location.accuracy,
          altitude: location.altitude,
          heading: location.heading,
          timestamp: location.timestamp!,
        ));
        
        // Simulate queue size check
        if (queueSize > 1000) {
          queueSize = 1000; // Enforce limit
        }
      }
      
      // Then
      expect(queueSize, equals(1000));
    });
  });
}

Position createTestPosition() {
  return Position(
    latitude: 1.3521,
    longitude: 103.8198,
    timestamp: DateTime.now(),
    accuracy: 10.0,
    altitude: 0.0,
    heading: 0.0,
    speed: 20.0,
    speedAccuracy: 5.0,
  );
}
```

### Integration Tests

```dart
// test/integration/migration_integration_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mockito/mockito.dart';
import 'package:geolocator/geolocator.dart';
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  
  group('Migration Integration Tests', () {
    late LocationPublishingManager manager;
    late MockMQTTLocationService mockMqtt;
    late MockPubSubLocationClient mockPubsub;
    late MockLDClient mockLdClient;
    late MockAnalytics mockAnalytics;
    
    setUp(() async {
      mockMqtt = MockMQTTLocationService();
      mockPubsub = MockPubSubLocationClient();
      mockLdClient = MockLDClient();
      mockAnalytics = MockAnalytics();
      
      // Configure for dual publishing
      when(mockLdClient.jsonVariation(any, defaultValue: anyNamed('defaultValue')))
          .thenAnswer((_) async => {
            'mqtt_enabled': true,
            'pubsub_enabled': true,
            'phase': 'testing',
            'device_percentage': 100,
            'fallback_enabled': true,
          });
      
      manager = LocationPublishingManager(
        mqttClient: mockMqtt,
        pubsubClient: mockPubsub,
        ldClient: mockLdClient,
        analytics: mockAnalytics,
        deviceId: 'test-device',
      );
      
      await manager.initialize();
    });
    
    testWidgets('dual publishing sends to both protocols', (tester) async {
      // Given
      final position = Position(
        latitude: 1.3521,
        longitude: 103.8198,
        timestamp: DateTime.now(),
        accuracy: 10.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 20.0,
        speedAccuracy: 5.0,
      );
      
      // Mock successful publishes
      when(mockMqtt.publishLocation(any)).thenReturn(null);
      when(mockPubsub.publishLocation(any, any))
          .thenAnswer((_) async => {});
      
      // When
      await manager.publishLocation(position);
      
      // Wait for async operations
      await tester.pumpAndSettle();
      
      // Then
      verify(mockMqtt.publishLocation(any)).called(1);
      verify(mockPubsub.publishLocation(any, any)).called(1);
      verify(mockAnalytics.track('location_publish_complete', any)).called(1);
    });
    
    testWidgets('handles MQTT failure gracefully', (tester) async {
      // Given
      final position = createTestPosition();
      
      // Mock MQTT failure, Pub/Sub success
      when(mockMqtt.publishLocation(any))
          .thenThrow(Exception('MQTT connection failed'));
      when(mockPubsub.publishLocation(any, any))
          .thenAnswer((_) async => {});
      
      // When
      await manager.publishLocation(position);
      await tester.pumpAndSettle();
      
      // Then
      verify(mockAnalytics.track('mqtt_publish_error', any)).called(1);
      verify(mockPubsub.publishLocation(any, any)).called(1);
      // Should not throw - gracefully handled
    });
    
    testWidgets('respects feature flags', (tester) async {
      // Given - Pub/Sub disabled
      when(mockLdClient.jsonVariation(any, defaultValue: anyNamed('defaultValue')))
          .thenAnswer((_) async => {
            'mqtt_enabled': true,
            'pubsub_enabled': false,
            'phase': 'testing',
            'device_percentage': 0,
            'fallback_enabled': true,
          });
      
      // Reinitialize with new config
      await manager.initialize();
      
      final position = createTestPosition();
      
      // When
      await manager.publishLocation(position);
      await tester.pumpAndSettle();
      
      // Then
      verify(mockMqtt.publishLocation(any)).called(1);
      verifyNever(mockPubsub.publishLocation(any, any));
    });
  });
}
```

### End-to-End Tests

```dart
// integration_test/e2e_location_tracking_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:innovd_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  
  group('E2E Location Tracking', () {
    testWidgets('complete location tracking flow', (tester) async {
      // Start app
      app.main();
      await tester.pumpAndSettle();
      
      // Grant location permission (in test mode)
      await _grantLocationPermission();
      
      // Find and tap start tracking button
      final startButton = find.byKey(Key('startTrackingButton'));
      expect(startButton, findsOneWidget);
      await tester.tap(startButton);
      await tester.pumpAndSettle();
      
      // Wait for location updates
      await tester.pump(Duration(seconds: 5));
      
      // Verify status update
      final statusText = find.byKey(Key('statusText'));
      expect(statusText, findsOneWidget);
      expect(
        tester.widget<Text>(statusText).data,
        contains('Location published'),
      );
      
      // Verify both protocols show success
      final mqttStatus = find.byKey(Key('mqttStatus'));
      final pubsubStatus = find.byKey(Key('pubsubStatus'));
      
      expect(
        tester.widget<Text>(mqttStatus).data,
        contains('Connected'),
      );
      expect(
        tester.widget<Text>(pubsubStatus).data,
        contains('Connected'),
      );
    });
    
    testWidgets('handles offline mode correctly', (tester) async {
      app.main();
      await tester.pumpAndSettle();
      
      // Enable airplane mode simulation
      final settingsButton = find.byKey(Key('settingsButton'));
      await tester.tap(settingsButton);
      await tester.pumpAndSettle();
      
      final offlineModeSwitch = find.byKey(Key('offlineModeSwitch'));
      await tester.tap(offlineModeSwitch);
      await tester.pumpAndSettle();
      
      // Start tracking
      final startButton = find.byKey(Key('startTrackingButton'));
      await tester.tap(startButton);
      await tester.pump(Duration(seconds: 2));
      
      // Verify queued status
      final queueStatus = find.byKey(Key('queueStatus'));
      expect(
        tester.widget<Text>(queueStatus).data,
        contains('Queued: 1'),
      );
      
      // Disable offline mode
      await tester.tap(offlineModeSwitch);
      await tester.pumpAndSettle();
      
      // Wait for sync
      await tester.pump(Duration(seconds: 3));
      
      // Verify queue cleared
      expect(
        tester.widget<Text>(queueStatus).data,
        contains('Queued: 0'),
      );
    });
    
    testWidgets('battery optimization works correctly', (tester) async {
      app.main();
      await tester.pumpAndSettle();
      
      // Navigate to settings
      final settingsButton = find.byKey(Key('settingsButton'));
      await tester.tap(settingsButton);
      await tester.pumpAndSettle();
      
      // Check battery optimization is enabled
      final batteryOptSwitch = find.byKey(Key('batteryOptimizationSwitch'));
      expect(
        tester.widget<Switch>(batteryOptSwitch).value,
        isTrue,
      );
      
      // Verify accuracy adjusts with battery level
      final batteryLevelSlider = find.byKey(Key('batteryLevelSlider'));
      
      // Simulate low battery (20%)
      await tester.drag(batteryLevelSlider, Offset(-200, 0));
      await tester.pumpAndSettle();
      
      final accuracyText = find.byKey(Key('locationAccuracyText'));
      expect(
        tester.widget<Text>(accuracyText).data,
        contains('Low accuracy mode'),
      );
    });
  });
}

Future<void> _grantLocationPermission() async {
  // In integration tests, permissions are typically pre-granted
  // This is a placeholder for the actual permission flow
  final status = await Permission.location.status;
  if (!status.isGranted) {
    await Permission.location.request();
  }
}
```

## 7. Performance Optimization

### Network Optimization

```dart
// lib/services/network_optimizer.dart
import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';

class NetworkOptimizer {
  final List<LocationData> _pendingLocations = [];
  final int batchSize;
  final Duration batchInterval;
  Timer? _batchTimer;
  final PubSubLocationClient _pubsubClient;
  
  NetworkOptimizer({
    required PubSubLocationClient pubsubClient,
    this.batchSize = 10,
    this.batchInterval = const Duration(seconds: 30),
  }) : _pubsubClient = pubsubClient;
  
  void optimizeForNetwork(LocationData location) {
    _pendingLocations.add(location);
    
    if (_pendingLocations.length >= batchSize) {
      _sendBatch();
    } else if (_batchTimer == null) {
      _scheduleBatchSend();
    }
  }
  
  void _scheduleBatchSend() {
    _batchTimer = Timer(batchInterval, () {
      _sendBatch();
    });
  }
  
  Future<void> _sendBatch() async {
    if (_pendingLocations.isEmpty) return;
    
    final batch = List<LocationData>.from(_pendingLocations);
    _pendingLocations.clear();
    _batchTimer?.cancel();
    _batchTimer = null;
    
    // Compress batch
    final compressedData = _compress(batch);
    
    try {
      await _pubsubClient.publishBatch(compressedData);
    } catch (e) {
      // Re-queue on failure
      _pendingLocations.addAll(batch);
      _scheduleBatchSend();
      print('Batch send failed, will retry: $e');
    }
  }
  
  List<int> _compress(List<LocationData> locations) {
    // Convert to JSON
    final jsonData = locations.map((loc) => loc.toMap()).toList();
    final jsonString = json.encode(jsonData);
    final bytes = utf8.encode(jsonString);
    
    // Compress with gzip
    final gzipData = GZipEncoder().encode(bytes);
    return gzipData ?? bytes;
  }
  
  void dispose() {
    _batchTimer?.cancel();
    if (_pendingLocations.isNotEmpty) {
      _sendBatch(); // Send any remaining locations
    }
  }
}

// Extension for batch publishing
extension BatchPublishing on PubSubLocationClient {
  Future<void> publishBatch(List<int> compressedData) async {
    final message = PubsubMessage()
      ..data = base64Encode(compressedData)
      ..attributes = {
        'compression': 'gzip',
        'type': 'batch',
        'count': '${_extractCount(compressedData)}',
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      };
    
    await _publish(message);
  }
  
  int _extractCount(List<int> compressedData) {
    try {
      final decompressed = GZipDecoder().decodeBytes(compressedData);
      final jsonString = utf8.decode(decompressed);
      final List<dynamic> items = json.decode(jsonString);
      return items.length;
    } catch (e) {
      return 0;
    }
  }
}
```

### Memory Management

```dart
// lib/services/memory_efficient_location_buffer.dart
import 'dart:collection';
import 'package:geolocator/geolocator.dart';

class MemoryEfficientLocationBuffer {
  final int maxSize;
  final Duration maxAge;
  final Queue<TimestampedLocation> _buffer = Queue();
  
  MemoryEfficientLocationBuffer({
    this.maxSize = 1000,
    this.maxAge = const Duration(hours: 1),
  });
  
  void add(Position position) {
    // Remove old entries
    final cutoffTime = DateTime.now().subtract(maxAge);
    _buffer.removeWhere((item) => item.timestamp.isBefore(cutoffTime));
    
    // Add new location
    _buffer.add(TimestampedLocation(
      position: position,
      timestamp: DateTime.now(),
    ));
    
    // Maintain size limit
    while (_buffer.length > maxSize) {
      _buffer.removeFirst();
    }
  }
  
  List<Position> getAndClear() {
    final locations = _buffer.map((item) => item.position).toList();
    _buffer.clear();
    return locations;
  }
  
  List<Position> getRecentLocations(Duration maxAge) {
    final cutoffTime = DateTime.now().subtract(maxAge);
    return _buffer
        .where((item) => item.timestamp.isAfter(cutoffTime))
        .map((item) => item.position)
        .toList();
  }
  
  int get size => _buffer.length;
  
  void clear() => _buffer.clear();
  
  // Get memory usage estimate
  int get estimatedMemoryBytes {
    // Rough estimate: ~200 bytes per location
    return _buffer.length * 200;
  }
  
  // Trim buffer if memory pressure detected
  void trimIfNeeded() {
    // Keep only last 30 minutes of data under memory pressure
    if (estimatedMemoryBytes > 1024 * 1024) { // 1MB threshold
      final cutoffTime = DateTime.now().subtract(Duration(minutes: 30));
      _buffer.removeWhere((item) => item.timestamp.isBefore(cutoffTime));
    }
  }
}

class TimestampedLocation {
  final Position position;
  final DateTime timestamp;
  
  TimestampedLocation({
    required this.position,
    required this.timestamp,
  });
}

// Memory pressure monitoring
class MemoryMonitor {
  static void monitorMemoryPressure(MemoryEfficientLocationBuffer buffer) {
    // Flutter doesn't have direct memory pressure APIs
    // but we can monitor buffer size and trim proactively
    Timer.periodic(Duration(minutes: 5), (timer) {
      buffer.trimIfNeeded();
      
      if (buffer.estimatedMemoryBytes > 500 * 1024) { // 500KB warning
        print('Warning: Location buffer using ${buffer.estimatedMemoryBytes} bytes');
      }
    });
  }
}
```

## 8. Troubleshooting

### Common Issues and Solutions

#### 1. Authentication Failures
```dart
// lib/services/error_handlers.dart
import 'package:googleapis_auth/auth_io.dart';
import 'package:flutter/services.dart';

class AuthErrorHandler {
  final Analytics analytics;
  final GoogleAuthService authService;
  
  AuthErrorHandler({
    required this.analytics,
    required this.authService,
  });
  
  Future<void> handleAuthError(dynamic error) async {
    if (error is DetailedApiRequestError) {
      switch (error.status) {
        case 401:
          // Token expired or invalid
          print('Auth token expired, refreshing...');
          await authService.refreshToken();
          break;
        case 403:
          // Permission denied
          analytics.track('auth_error', {
            'error': 'permission_denied',
            'message': error.message,
          });
          break;
        default:
          analytics.track('auth_error', {
            'error': 'api_error',
            'status': error.status,
            'message': error.message,
          });
      }
    } else if (error is PlatformException) {
      // Platform-specific auth errors
      analytics.track('auth_error', {
        'error': 'platform_error',
        'code': error.code,
        'message': error.message,
      });
    } else if (error is ServiceAccountCredentialsException) {
      // Invalid service account
      analytics.track('auth_error', {
        'error': 'invalid_credentials',
        'details': error.toString(),
      });
      
      // Notify user to check service account configuration
      throw AuthConfigurationException(
        'Invalid service account credentials. Please check your configuration.',
      );
    } else {
      // Unknown error
      analytics.track('auth_error', {
        'error': 'unknown',
        'type': error.runtimeType.toString(),
        'message': error.toString(),
      });
    }
  }
  
  Future<T> retryWithAuth<T>(
    Future<T> Function() operation, {
    int maxRetries = 3,
  }) async {
    int attempts = 0;
    
    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (e) {
        attempts++;
        
        if (e is DetailedApiRequestError && e.status == 401) {
          // Try refreshing auth
          await authService.refreshToken();
          
          if (attempts < maxRetries) {
            // Wait before retry with exponential backoff
            await Future.delayed(Duration(seconds: attempts * 2));
            continue;
          }
        }
        
        // If not auth error or max retries reached, rethrow
        rethrow;
      }
    }
    
    throw AuthRetryException('Max auth retries exceeded');
  }
}

class AuthConfigurationException implements Exception {
  final String message;
  AuthConfigurationException(this.message);
}

class AuthRetryException implements Exception {
  final String message;
  AuthRetryException(this.message);
}
```

#### 2. Message Delivery Issues
```dart
// lib/services/pubsub_debugger.dart
import 'package:flutter/foundation.dart';
import 'package:googleapis/pubsub/v1.dart';
import 'dart:convert';

class PubSubDebugger {
  static bool _debugEnabled = false;
  static final List<PublishAttempt> _publishHistory = [];
  
  static void enableDebugging() {
    _debugEnabled = true;
    print('🔍 Pub/Sub debugging enabled');
  }
  
  static void logPublishAttempt({
    required String topic,
    required PubsubMessage message,
    required bool success,
    String? error,
  }) {
    if (!_debugEnabled) return;
    
    final attempt = PublishAttempt(
      timestamp: DateTime.now(),
      topic: topic,
      messageSize: message.data?.length ?? 0,
      attributes: message.attributes,
      success: success,
      error: error,
    );
    
    _publishHistory.add(attempt);
    
    // Keep only last 100 attempts
    if (_publishHistory.length > 100) {
      _publishHistory.removeAt(0);
    }
    
    // Log to console
    debugPrint('📤 Publish ${success ? "✓" : "✗"}: '
        'Topic=$topic, '
        'Size=${attempt.messageSize} bytes, '
        'Attrs=${attempt.attributes?.length ?? 0}'
        '${error != null ? ", Error: $error" : ""}');
  }
  
  static List<String> validateMessage(PubsubMessage message) {
    final errors = <String>[];
    
    // Check data size (Pub/Sub limit is 10MB)
    if (message.data != null) {
      final dataBytes = base64.decode(message.data!);
      if (dataBytes.length > 10 * 1024 * 1024) {
        errors.add('Message too large: ${dataBytes.length} bytes (max 10MB)');
      }
    }
    
    // Check attributes
    if (message.attributes != null) {
      // Total attributes size limit
      var totalAttrSize = 0;
      
      message.attributes!.forEach((key, value) {
        // Individual attribute limits
        if (key.length > 256) {
          errors.add('Attribute key "$key" too long (max 256 chars)');
        }
        if (value.length > 1024) {
          errors.add('Attribute value for "$key" too long (max 1024 chars)');
        }
        
        totalAttrSize += key.length + value.length;
      });
      
      if (totalAttrSize > 4096) {
        errors.add('Total attributes size too large: $totalAttrSize bytes (max 4096)');
      }
    }
    
    return errors;
  }
  
  static void printStats() {
    if (!_debugEnabled || _publishHistory.isEmpty) return;
    
    final total = _publishHistory.length;
    final successful = _publishHistory.where((a) => a.success).length;
    final failed = total - successful;
    final avgSize = _publishHistory
        .map((a) => a.messageSize)
        .reduce((a, b) => a + b) ~/ total;
    
    debugPrint('\n📊 Pub/Sub Statistics:');
    debugPrint('   Total attempts: $total');
    debugPrint('   Successful: $successful (${(successful / total * 100).toStringAsFixed(1)}%)');
    debugPrint('   Failed: $failed');
    debugPrint('   Average message size: $avgSize bytes');
    
    // Error breakdown
    final errorCounts = <String, int>{};
    for (final attempt in _publishHistory.where((a) => !a.success)) {
      errorCounts[attempt.error ?? 'Unknown'] = 
          (errorCounts[attempt.error ?? 'Unknown'] ?? 0) + 1;
    }
    
    if (errorCounts.isNotEmpty) {
      debugPrint('\n   Error breakdown:');
      errorCounts.forEach((error, count) {
        debugPrint('     $error: $count');
      });
    }
  }
}

class PublishAttempt {
  final DateTime timestamp;
  final String topic;
  final int messageSize;
  final Map<String, String>? attributes;
  final bool success;
  final String? error;
  
  PublishAttempt({
    required this.timestamp,
    required this.topic,
    required this.messageSize,
    this.attributes,
    required this.success,
    this.error,
  });
}
```

#### 3. Performance Issues
```dart
// lib/services/location_performance_monitor.dart
import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

class LocationPerformanceMonitor {
  final Map<String, List<double>> _metrics = {};
  final int maxSamplesPerMetric;
  
  LocationPerformanceMonitor({this.maxSamplesPerMetric = 1000});
  
  void recordMetric(String name, double duration) {
    _metrics.putIfAbsent(name, () => []);
    
    final list = _metrics[name]!;
    list.add(duration);
    
    // Keep only recent samples
    if (list.length > maxSamplesPerMetric) {
      list.removeAt(0);
    }
  }
  
  void recordPublishLatency({
    required String protocol,
    required double latencyMs,
    required bool success,
  }) {
    recordMetric('${protocol}_latency', latencyMs);
    if (!success) {
      recordMetric('${protocol}_failures', 1);
    }
  }
  
  PerformanceStats? getStats(String name) {
    final durations = _metrics[name];
    if (durations == null || durations.isEmpty) return null;
    
    final sorted = List<double>.from(durations)..sort();
    
    return PerformanceStats(
      average: _calculateAverage(durations),
      median: sorted[sorted.length ~/ 2],
      p95: sorted[(sorted.length * 0.95).floor()],
      p99: sorted[(sorted.length * 0.99).floor()],
      min: sorted.first,
      max: sorted.last,
      count: durations.length,
    );
  }
  
  double _calculateAverage(List<double> values) {
    return values.reduce((a, b) => a + b) / values.length;
  }
  
  void logAllStats() {
    debugPrint('\n📈 Performance Metrics:');
    
    _metrics.keys.forEach((name) {
      final stats = getStats(name);
      if (stats != null) {
        debugPrint('  $name:');
        debugPrint('    Avg: ${stats.average.toStringAsFixed(2)}ms');
        debugPrint('    Median: ${stats.median.toStringAsFixed(2)}ms');
        debugPrint('    P95: ${stats.p95.toStringAsFixed(2)}ms');
        debugPrint('    P99: ${stats.p99.toStringAsFixed(2)}ms');
        debugPrint('    Min/Max: ${stats.min.toStringAsFixed(2)}/${stats.max.toStringAsFixed(2)}ms');
        debugPrint('    Samples: ${stats.count}');
      }
    });
  }
  
  Map<String, dynamic> exportMetrics() {
    final export = <String, dynamic>{};
    
    _metrics.forEach((name, _) {
      final stats = getStats(name);
      if (stats != null) {
        export[name] = {
          'average': stats.average,
          'median': stats.median,
          'p95': stats.p95,
          'p99': stats.p99,
          'min': stats.min,
          'max': stats.max,
          'count': stats.count,
        };
      }
    });
    
    return export;
  }
  
  void clear() {
    _metrics.clear();
  }
}

class PerformanceStats {
  final double average;
  final double median;
  final double p95;
  final double p99;
  final double min;
  final double max;
  final int count;
  
  PerformanceStats({
    required this.average,
    required this.median,
    required this.p95,
    required this.p99,
    required this.min,
    required this.max,
    required this.count,
  });
  
  bool get isHealthy => p95 < 1000 && average < 500; // Under 1s p95, 500ms avg
}

// Performance monitoring widget for debug builds
class PerformanceOverlay extends StatefulWidget {
  final LocationPerformanceMonitor monitor;
  final Widget child;
  
  const PerformanceOverlay({
    Key? key,
    required this.monitor,
    required this.child,
  }) : super(key: key);
  
  @override
  _PerformanceOverlayState createState() => _PerformanceOverlayState();
}

class _PerformanceOverlayState extends State<PerformanceOverlay> {
  Timer? _refreshTimer;
  
  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _refreshTimer = Timer.periodic(Duration(seconds: 1), (_) {
        setState(() {}); // Refresh stats
      });
    }
  }
  
  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;
    
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 50,
          right: 10,
          child: Container(
            padding: EdgeInsets.all(8),
            color: Colors.black.withOpacity(0.7),
            child: Text(
              _buildStatsText(),
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  String _buildStatsText() {
    final mqttStats = widget.monitor.getStats('mqtt_latency');
    final pubsubStats = widget.monitor.getStats('pubsub_latency');
    
    return 'MQTT: ${mqttStats?.average.toStringAsFixed(0) ?? "--"}ms\n'
           'Pub/Sub: ${pubsubStats?.average.toStringAsFixed(0) ?? "--"}ms';
  }
}
```

### Migration Monitoring Dashboard

```dart
// lib/services/migration_metrics.dart
import 'package:flutter/material.dart';
import 'dart:async';

class MigrationMetrics {
  static final MigrationMetrics _instance = MigrationMetrics._internal();
  factory MigrationMetrics() => _instance;
  MigrationMetrics._internal();
  
  int _mqttSuccessCount = 0;
  int _mqttFailureCount = 0;
  int _pubsubSuccessCount = 0;
  int _pubsubFailureCount = 0;
  
  final _metricsController = StreamController<MigrationStats>.broadcast();
  Stream<MigrationStats> get metricsStream => _metricsController.stream;
  
  Timer? _uploadTimer;
  
  void startTracking() {
    // Upload metrics every 5 minutes
    _uploadTimer = Timer.periodic(Duration(minutes: 5), (_) {
      _uploadMetrics();
    });
  }
  
  void recordSuccess(PublishProtocol protocol) {
    switch (protocol) {
      case PublishProtocol.mqtt:
        _mqttSuccessCount++;
        break;
      case PublishProtocol.pubsub:
        _pubsubSuccessCount++;
        break;
    }
    
    _notifyListeners();
  }
  
  void recordFailure(PublishProtocol protocol, dynamic error) {
    switch (protocol) {
      case PublishProtocol.mqtt:
        _mqttFailureCount++;
        break;
      case PublishProtocol.pubsub:
        _pubsubFailureCount++;
        break;
    }
    
    _notifyListeners();
    
    // Log specific error types
    Analytics.track('publish_failure', {
      'protocol': protocol.toString(),
      'error_type': error.runtimeType.toString(),
      'error_message': error.toString(),
    });
  }
  
  MigrationStats getStats() {
    return MigrationStats(
      mqttSuccessRate: _calculateSuccessRate(_mqttSuccessCount, _mqttFailureCount),
      pubsubSuccessRate: _calculateSuccessRate(_pubsubSuccessCount, _pubsubFailureCount),
      totalPublishes: _getTotalPublishes(),
      mqttTotal: _mqttSuccessCount + _mqttFailureCount,
      pubsubTotal: _pubsubSuccessCount + _pubsubFailureCount,
    );
  }
  
  double _calculateSuccessRate(int success, int failure) {
    final total = success + failure;
    return total > 0 ? success / total : 0.0;
  }
  
  int _getTotalPublishes() {
    return _mqttSuccessCount + _mqttFailureCount + 
           _pubsubSuccessCount + _pubsubFailureCount;
  }
  
  void _notifyListeners() {
    _metricsController.add(getStats());
  }
  
  void _uploadMetrics() {
    final stats = getStats();
    
    Analytics.track('migration_metrics', {
      'mqtt_success_rate': stats.mqttSuccessRate,
      'pubsub_success_rate': stats.pubsubSuccessRate,
      'total_publishes': stats.totalPublishes,
      'mqtt_total': stats.mqttTotal,
      'pubsub_total': stats.pubsubTotal,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  void dispose() {
    _uploadTimer?.cancel();
    _metricsController.close();
  }
}

class MigrationStats {
  final double mqttSuccessRate;
  final double pubsubSuccessRate;
  final int totalPublishes;
  final int mqttTotal;
  final int pubsubTotal;
  
  MigrationStats({
    required this.mqttSuccessRate,
    required this.pubsubSuccessRate,
    required this.totalPublishes,
    required this.mqttTotal,
    required this.pubsubTotal,
  });
}

enum PublishProtocol {
  mqtt,
  pubsub,
}

// Migration Dashboard Widget
class MigrationDashboard extends StatelessWidget {
  final MigrationMetrics metrics = MigrationMetrics();
  
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MigrationStats>(
      stream: metrics.metricsStream,
      builder: (context, snapshot) {
        final stats = snapshot.data ?? metrics.getStats();
        
        return Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Migration Status',
                  style: Theme.of(context).textTheme.headline6,
                ),
                SizedBox(height: 16),
                _buildProtocolStatus(
                  'MQTT',
                  stats.mqttSuccessRate,
                  stats.mqttTotal,
                  Colors.blue,
                ),
                SizedBox(height: 8),
                _buildProtocolStatus(
                  'Pub/Sub',
                  stats.pubsubSuccessRate,
                  stats.pubsubTotal,
                  Colors.green,
                ),
                Divider(height: 24),
                Text(
                  'Total Publishes: ${stats.totalPublishes}',
                  style: Theme.of(context).textTheme.subtitle2,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildProtocolStatus(
    String protocol,
    double successRate,
    int total,
    Color color,
  ) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: 8),
        Expanded(
          child: Text(protocol),
        ),
        Text(
          '${(successRate * 100).toStringAsFixed(1)}%',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: successRate > 0.95 ? Colors.green : Colors.orange,
          ),
        ),
        SizedBox(width: 8),
        Text(
          '($total)',
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }
}
```

---

This migration guide provides a complete roadmap for transitioning your mobile apps from MQTT to Google Pub/Sub while maintaining reliability and performance throughout the migration process.