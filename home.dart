import 'dart:async';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rive/rive.dart';
import 'package:sensors/components/bck_btn.dart';
import 'package:sensors/components/standard_format.dart';
import 'package:sensors/design-sys/ui_helpers.dart';
import 'package:sensors/pages/home/ui/action_below.dart';
import 'package:sensors/pages/home/ui/cstm_btn.dart';
import 'package:sensors/pages/home/ui/sensor_detail.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../../design-sys/app_font.dart';
import '../../design-sys/colors.dart';
import '../../utils/utils.dart';
import 'ui/dot_effect.dart';
import 'ui/timenstatus.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Artboard? _artboard;
  StateMachineController? _controller;
  StreamSubscription<UserAccelerometerEvent>? _accelerometerSubscription;
  UserAccelerometerEvent? _accelerometer;

  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  GyroscopeEvent? _gyroscope;

  StreamSubscription<MagnetometerEvent>? _magnetometerSubscription;
  MagnetometerEvent? _magnetometer;

  final List<List<dynamic>> _sensorData = [];

  Position? _lastPosition;
  String? _filename;
  double _speed = 0;

  Timer? _timer;
  int _seconds = 0;

  void _startTimer() {
    if (_controller != null && _controller!.isActive) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _seconds++;
        });
      });
    }
  }

  void _pauseTimer() {
    _timer?.cancel();
    setState(() {
      _animationStatus = false;
      _sensorActivated = false;
      if (_controller != null) {
        _controller!.isActive = _animationStatus;
      }
    });

    if (_animationStatus == false) {
      _pauseSensors();
    }
  }

  Future<void> _stopTimer() async {
    _timer?.cancel();
    setState(() {
      _seconds = 0;
      _animationStatus = false;
      _playAnimation = false;
      _showBelowControl = false;
      _sensorActivated = false;
      if (_controller != null) {
        _controller!.isActive = _animationStatus;
      }
    });

    _loadRiveFile();

    // Export data to CSV file
    if (_filename != null) {
      String csv = const ListToCsvConverter().convert([
        [
          'Timestamp',
          'Accelerometer X',
          'Accelerometer Y',
          'Accelerometer Z',
          'Speed',
          'Lat',
          "Long",
          'Gyroscope X',
          'Gyroscope Y',
          'Gyroscope Z',
          'Magnetometer X',
          'Magnetometer Y',
          'Magnetometer Z'
        ],
        ..._sensorData,
      ]);

      // Open file picker dialog to select directory
      final directory = await getExternalStorageDirectory();
      final pathOfTheFileToWrite = "${directory!.path}/$_filename.csv";
      final file = File(pathOfTheFileToWrite);
      await file.writeAsString(csv);

      final String? userEmail = FirebaseAuth.instance.currentUser?.email;

      if (userEmail != null) {
        final Email email = Email(
          body: 'Attached is the sensor data file.',
          subject: 'Sensor Data: $_filename.csv',
          recipients: [userEmail], // User's registered email
          attachmentPaths: [pathOfTheFileToWrite],
        );

        try {
          await FlutterEmailSender.send(email);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text("The Data saved and sent to your mail."),
              ),
            );
          }
        } catch (error) {
          if (kDebugMode) {
            print('Error sending email: $error');
          }
        }
      } else {
        if (kDebugMode) {
          print('User email is null');
        }
      }
    }

    _pauseSensors();
  }

  void _playTimer() {
    setState(() {
      _animationStatus = true;
      if (_controller != null) {
        _controller!.isActive = _animationStatus;
      }
    });

    if (_animationStatus == true) {
      _startTimer();
      _activateSensors();
    }
  }

  Future<void> _requestPermissions() async {
    PermissionStatus notificationStatus = await Permission.notification.status;
    LocationPermission locationStatus = await Geolocator.checkPermission();

    if (notificationStatus.isDenied) {
      await Permission.notification.request();
    }

    if (locationStatus == LocationPermission.denied ||
        locationStatus == LocationPermission.deniedForever) {
      await Geolocator.requestPermission();

      if (mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Location Permission Required'),
              content: const Text(
                  'Please grant location permission to use this app, if you have given then pls restart the app.'),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    SystemNavigator.pop(); // Close the app
                  },
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    }
  }

  bool _playAnimation = false;
  bool _animationStatus = false;
  bool _showBelowControl = false;
  bool _sensorActivated = false;

  void _activateSensors() {
    if (!_sensorActivated) {
      _sensorActivated = true;
      _accelerometerSubscription?.resume();
      _gyroscopeSubscription?.resume();
      _magnetometerSubscription?.resume();
    }
  }

  void _pauseSensors() {
    if (!_sensorActivated) {
      _sensorActivated = false;
      _accelerometerSubscription?.pause();
      _gyroscopeSubscription?.pause();
      _magnetometerSubscription?.pause();
    }
  }

  Future<void> playAnimation() async {
    if (!_playAnimation) {
      String? fileName = await _showFileNameDialog();
      if (fileName != null && fileName.isNotEmpty) {
        _sensorData.clear();
        setState(() {
          _filename = fileName;
          _playAnimation = true;
          _showBelowControl = true;
          _animationStatus = true;
          if (_controller != null) {
            _controller!.isActive = _animationStatus;
            if (_playAnimation) {
              _startTimer();
            }
          }
        });
      }
    }
  }

  void _recordSensorData(String sensorType, List<double> values) {
    if (!_animationStatus) {
      return; // Do not record data if animation is not playing
    }

    DateTime timestamp = DateTime.now().toUtc();
    double? x, y, z;
    if (values.length >= 3) {
      x = values[0];
      y = values[1];
      z = values[2];
    }

    double speedKmHr = _speed * 3.6; // Convert speed from m/s to km/hr

    if (sensorType == 'Accelerometer') {
      // Start a new row with accelerometer data
      _sensorData.add([
        timestamp.toIso8601String(),
        x ?? 0,
        y ?? 0,
        z ?? 0,
        speedKmHr, // Add converted speed to the data
        _lastPosition?.latitude ?? 0, // Add latitude
        _lastPosition?.longitude ?? 0, // Add longitude
        0, // Placeholder for gyroscope X
        0, // Placeholder for gyroscope Y
        0, // Placeholder for gyroscope Z
        0, // Placeholder for magnetometer X
        0, // Placeholder for magnetometer Y
        0, // Placeholder for magnetometer Z
      ]);
    } else if (_sensorData.isNotEmpty) {
      // Add gyroscope and magnetometer data to the last row
      int lastIndex = _sensorData.length - 1;
      if (sensorType == 'Gyroscope') {
        _sensorData[lastIndex][7] = x ?? 0;
        _sensorData[lastIndex][8] = y ?? 0;
        _sensorData[lastIndex][9] = z ?? 0;
      } else if (sensorType == 'Magnetometer') {
        _sensorData[lastIndex][10] = x ?? 0;
        _sensorData[lastIndex][11] = y ?? 0;
        _sensorData[lastIndex][12] = z ?? 0;
      }
    }
  }

  Future<String?> _showFileNameDialog() async {
    TextEditingController fileNameController = TextEditingController();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return GestureDetector(
          onTap: () {
            // Dismiss the keyboard if it's open
            FocusScopeNode currentFocus = FocusScope.of(context);
            if (!currentFocus.hasPrimaryFocus) {
              currentFocus.unfocus();
            }
            // Dismiss the dialog
            Navigator.of(context).pop(null);
          },
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: TextField(
                controller: fileNameController,
                textAlign: TextAlign.left,
                scribbleEnabled: true,
                style: const TextStyle(
                  color: AppTheme.textMainColor,
                  fontSize: AppFont.subtitle1,
                  fontWeight: FontWeight.w800,
                ),
                decoration: const InputDecoration(
                  hintText: 'Enter your filename...',
                  contentPadding: EdgeInsets.all(16.0),
                  enabledBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: AppTheme.ternaryAppColor, width: 0.8),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: AppTheme.primaryAppColor, width: 0.8),
                  ),
                  hintStyle: TextStyle(
                    color: AppTheme.textSecColor,
                    fontSize: AppFont.subtitle1,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onSubmitted: (value) {
                  // Get the current date and time
                  DateTime now = DateTime.now();
                  String formattedDate =
                      '${now.year}-${now.month}-${now.day}T${now.hour}:${now.minute}:${now.second}';
                  Navigator.of(context).pop("$value - $formattedDate");
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _loadRiveFile() async {
    rootBundle.load('assets/rive/Sensing.riv').then((data) async {
      try {
        final file = RiveFile.import(data);
        final artboard = file.mainArtboard;
        _controller =
            StateMachineController.fromArtboard(artboard, 'State Machine 1');
        if (_controller != null) {
          artboard.addController(_controller!);
          _controller!.isActive = _playAnimation;
        }

        setState(() {
          _artboard = artboard;
        });
      } catch (e) {
        if (kDebugMode) {
          print(e);
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadRiveFile();

    _accelerometerSubscription = userAccelerometerEventStream(
      samplingPeriod: const Duration(
          milliseconds:
              20), // Set the interval to 20 milliseconds (50 samples per second)
    ).listen((UserAccelerometerEvent event) {
      if (_playAnimation) {
        _recordSensorData('Accelerometer', [event.x, event.y, event.z]);
      }
      setState(() {
        _accelerometer = event;
      });
    });

    // Subscribe to gyroscope events
    _gyroscopeSubscription = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen((GyroscopeEvent event) {
      if (_playAnimation) {
        _recordSensorData('Gyroscope', [event.x, event.y, event.z]);
      }
      setState(() {
        _gyroscope = event;
      });
    });

    // Subscribe to magnetometer events
    _magnetometerSubscription = magnetometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen((MagnetometerEvent event) {
      if (_playAnimation) {
        _recordSensorData('Magnetometer', [event.x, event.y, event.z]);
      }
      setState(() {
        _magnetometer = event;
      });
    });

    // Listen to location updates
    Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
      // Haversine formula
      if (_lastPosition != null) {
        double distanceInMeters = Geolocator.distanceBetween(
            _lastPosition!.latitude,
            _lastPosition!.longitude,
            position.latitude,
            position.longitude);
        double timeInSeconds = (position.timestamp.millisecondsSinceEpoch -
                _lastPosition!.timestamp.millisecondsSinceEpoch) /
            1000;
        _speed = distanceInMeters / timeInSeconds;
      }

      // Euclidean distance
      //   if (_lastPosition != null) {
      //     // Convert latitude and longitude to meters
      //     double lat1 = _lastPosition!.latitude;
      //     double lon1 = _lastPosition!.longitude;
      //     double lat2 = position.latitude;
      //     double lon2 = position.longitude;
      //
      //     // Calculate distance using Euclidean distance formula
      //     double deltaX = lat2 - lat1;
      //     double deltaY = lon2 - lon1;
      //     double distanceInMeters = sqrt(deltaX * deltaX + deltaY * deltaY);
      //
      //     // Calculate time difference in hours
      //     double timeInSeconds = (position.timestamp.millisecondsSinceEpoch - _lastPosition!.timestamp.millisecondsSinceEpoch) / 1000;
      //     double timeInHours = timeInSeconds / 3600; // Convert seconds to hours
      //
      //     // Calculate speed in kilometers per hour
      //     _speed = distanceInMeters / timeInHours;
      //   }
      _lastPosition = position;
    });
  }

  @override
  void dispose() {
    super.dispose();
    _controller?.dispose();
    _timer?.cancel();
    _accelerometerSubscription?.cancel();
    _gyroscopeSubscription?.cancel();
    _magnetometerSubscription?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return StdFormat(
      showKeyboard: false,
      widget: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomButtonTest(),
              const SizedBox(
                height: 32,
              ),
              TimeAndStatus(
                isRecording: _animationStatus,
                isSave: false,
              )
            ],
          ),
          if (_artboard != null) ...[
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  height: screenHeight(context) * 0.42,
                  width: screenWidth(context) * 2,
                  child: Rive(artboard: _artboard!),
                ),
              ),
            )
          ] else ...[
            Container()
          ],
          Align(
              alignment: Alignment.center,
              child: Visibility(
                visible: !_playAnimation,
                child: BackBtn(
                    callback: playAnimation,
                    iconSize: 36,
                    iconType: Icons.play_arrow_rounded),
              )),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedOpacity(
                opacity: _showBelowControl ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  color: AppTheme.mainAppColor,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SensingStateEffect(playAnimation: _animationStatus),
                      SensorDetail(
                        animationStatus: _animationStatus,
                        speed: _speed,
                        accelerometerEvent: _accelerometer,
                        gyroscopeEvent: _gyroscope,
                        magnetometerEvent: _magnetometer,
                      ),
                      ActionBelow(
                        seconds: _seconds,
                        onPause: _pauseTimer,
                        onPlay: _playTimer,
                        onStop: _stopTimer,
                        timer:
                            _timer ?? Timer(const Duration(seconds: 0), () {}),
                        stateActive: _animationStatus,
                        // onStateChange: (state) {
                        //   setState(() {
                        //     _animationStatus = state;
                        //   });
                        // },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
