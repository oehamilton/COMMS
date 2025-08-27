import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:intl/intl.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'amplify_outputs.dart'; // Generated from Environment Build
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
//import 'package:flutter_background_service_android/flutter_background_service_android.dart';
//import 'package:flutter/plugins.dart' show DartPluginRegistrant;

bool isSubscriptionActive = false;
void main() async {
  try {
      WidgetsFlutterBinding.ensureInitialized();
      await _configureAmplify();
      runApp(const MyApp());
      } on AmplifyException catch (e) {
           runApp(Text("Error configuring Amplify: ${e.message}"));
          }

}

/////////////////////////////////////////////////////////////////////////////////////////////
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'foreground_channel',
    'Background Subscription Service',
    description: 'Keeps subscriptions active in the background',
    importance: Importance.low,
  );
  final FlutterLocalNotificationsPlugin notificationsPlugin = FlutterLocalNotificationsPlugin();
  await notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'foreground_channel',
      initialNotificationTitle: 'COMMS DASHBOARD Running',
      initialNotificationContent: 'Listening for messages...',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: const [AndroidForegroundType.dataSync],  // Aligns with manifest
    ),
    iosConfiguration: IosConfiguration(),
  );

  await service.startService();
  safePrint('Background service started');
}

// This runs in the background isolate
//////////////////////////////////////////////////////////////////////
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();  // Initialize plugins in isolate

  // Re-initialize Amplify
  await _configureAmplify();

  // Load preferences (SharedPreferences works in isolates)
  final prefs = await SharedPreferences.getInstance();
  String? phoneNumber = prefs.getString('phone_number');
  if (phoneNumber != null) {
    phoneNumber = '+1$phoneNumber';  // Format if needed
  }
  final registrationSecret = prefs.getString('registration_secret');

  // Authentication logic (adapted from _checkAuthState and _signInWithPhone)
  bool isAuthenticated = false;
  try {
    final session = await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;
    if (session.isSignedIn) {
      isAuthenticated = true;
      safePrint('Background: Already signed in');
    } else {
      safePrint('Background: Not signed in, attempting sign-in');
      if (phoneNumber != null && registrationSecret != null) {
        final result = await Amplify.Auth.signIn(
          username: phoneNumber,
          password: registrationSecret,
        );
        if (result.isSignedIn) {
          isAuthenticated = true;
          safePrint('Background: Authenticated');
        } else {
          safePrint('Background: Sign-in failed: ${result.nextStep.signInStep}');
        }
      }
    }
  } catch (e) {
    safePrint('Background: Auth failed: $e');
  }

  // Initialize notifications in isolate
  final notificationsPlugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await notificationsPlugin.initialize(initSettings);

  // Initialize database in isolate (for persisting messages)
  Database? database;
  try {
    database = await openDatabase(
      path.join(await getDatabasesPath(), 'comms_database.db'),
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE messages(id INTEGER PRIMARY KEY, dynamo_id TEXT UNIQUE, sourceName TEXT, title TEXT, content TEXT, timestamp TEXT, isViewed INTEGER)',
        );
      },
      version: 1,
    );
  } catch (e) {
    safePrint('Background: DB init failed: $e');
  }

  StreamSubscription? subscription;
////////////////////////////////////////////////////////////////////////////////////////////////////
  // Subscription logic (adapted from _subscribeToMessages)
  void subscribeToMessages() {
    if (phoneNumber != null) {
      const String subscriptionDoc = r'''
        subscription OnCreateMessage($phoneNumber: String!) {
          onCreateMessage(filter: {phoneNumber: {eq: $phoneNumber}}) {
            id
            phoneNumber
            sourceName
            title
            content
            timestamp
            isViewed
          }
        }
      ''';

      final subscriptionRequest = GraphQLRequest<String>(
        document: subscriptionDoc,
        variables: {'phoneNumber': phoneNumber},
        decodePath: 'onCreateMessage',
      );

      final operation = Amplify.API.subscribe(
        subscriptionRequest,
        onEstablished: () {
          safePrint('Background: Subscription established for $phoneNumber');
          isSubscriptionActive = true;
        },
      );

      subscription = operation.listen(
        (event) {
          if (event.data != null) {
            final jsonMap = json.decode(event.data!) as Map<String, dynamic>;
            final inner = jsonMap['onCreateMessage'] as Map<String, dynamic>;
            final theMessage = Message(
              id: inner['id'] as String,
              sourceName: inner['sourceName'] as String,
              title: inner['title'] as String,
              content: inner['content'] as String,
              timestamp: DateTime.parse(inner['timestamp'] as String),
              isViewed: inner['isViewed'] as bool,
            );

            // Show notification
            notificationsPlugin.show(
              0,
              theMessage.title,
              theMessage.content,
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'channel_id',
                  'Channel Name',
                  channelDescription: 'Channel Description',
                  importance: Importance.max,
                  priority: Priority.high,
                ),
              ),
            );

            // Persist to DB if initialized
            if (database != null) {
            try {
              database.insert('messages', theMessage.toMap());
              //Update DynamoDB message isViewed to true
              safePrint('Background: Message persisted');
              _updateMessageInDynamoDB(theMessage.id);
            } catch (e) {
              safePrint('Background: Message insert failed: $e');
            }
          }
          }
        },
        onError: (error) {
          safePrint('Background: Subscription error: $error');
          isSubscriptionActive = false;  // Reset flag on error
          subscription?.cancel();
          subscription = null;
        },
        onDone: () {
          safePrint('Background: Subscription completed');
          isSubscriptionActive = false;
          subscription = null;
        },
      );
      safePrint('Background: Subscribed to messages');
    }
  }

  if (isAuthenticated && phoneNumber != null) {
    subscribeToMessages();
  }

  // Lifecycle handling
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    
    });
  }

  // Periodic reconnection (every 30 seconds)
  Timer.periodic(const Duration(seconds: 30), (timer) async {
    if (!isSubscriptionActive) {
      safePrint('Background: Subscription inactive, reconnecting');
      subscription?.cancel();
      subscription = null;
      if (isAuthenticated) {
        subscribeToMessages();
      } else {
        // Re-auth if needed (add retry auth logic here if session expires)
      }
    }
  });
}

  Future<void> _updateMessageInDynamoDB(String id) async {
    const String updateDoc = r'''
      mutation UpdateMessage($id: ID!, $isViewed: Boolean!) {
        updateMessage(input: {id: $id, isViewed: $isViewed}) {
          id
          isViewed
        }
      }
    ''';

    final updateRequest = GraphQLRequest<String>(
      document: updateDoc,
      variables: {'id': id, 'isViewed': true},
    );

    try {
      final response = await Amplify.API.mutate(request: updateRequest).response;
      if (response.errors.isNotEmpty) {
        safePrint('DynamoDB update error: ${response.errors}');
      } else {
        safePrint('DynamoDB updated isViewed to true for id: $id');
      }
    } catch (e) {
      safePrint('DynamoDB update failed: $e');
    }
  }


Future<void> _configureAmplify() async {
  try {
    await Amplify.addPlugins([AmplifyAuthCognito(), AmplifyAPI()]);
    await Amplify.configure(amplifyConfig);
    safePrint('Amplify configured successfully');
  } on AmplifyException catch (e) {
    safePrint('Failed to configure Amplify: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'COMMS DASHBOARD',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(150, 209, 14, 40)),
      ),
      home: const MyHomePage(title: 'COMMS DASHBOARD'),
    );
  }
}

// Message model with DateTime
class Message {
  final String id;
  final String sourceName;
  final String title;
  final String content;
  final DateTime timestamp; // New DateTime field
  bool isViewed;

  Message({
    required this.id,
    required this.sourceName,
    required this.title,
    required this.content,
    required this.timestamp,
    this.isViewed = false,
  });

// Convert Message to Map for database
  Map<String, dynamic> toMap() {
    return {
      'dynamo_id': id,
      'sourceName': sourceName,
      'title': title,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isViewed': isViewed ? 1 : 0,
    };
  }

  // Create Message from Map
  static Message fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['dynamo_id'] as String,
      sourceName: map['sourceName'],
      title: map['title'],
      content: map['content'],
      timestamp: DateTime.parse(map['timestamp']),
      isViewed: map['isViewed'] == 1,
    );
  }
}
/////////////////////////////////////////////////////////////////////////////////////
// Enum for menu options
////////////////////////////////////////////////////////////////////////////////////
enum MenuOption { viewSettings, updatePhone, messageRetention, purgeOldMessages, updateSecret, registerApplication, getMissedMessages }

////////////////////////////////////////////////////////////////////////////////////

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  Database? _database;
  List<Message> _messages = [];
  Message? _selectedMessage;
  final DateFormat _dateFormat = DateFormat('MM/dd/yyyy HH:mm:ss');
  String? _phoneNumber;
  String? _registrationSecret;
  int? _messageRetentionDays;
  bool _showUnreadOnly = false;
  bool _isAuthenticated = false;
  late SharedPreferences _prefs;
  late GraphQLClient _graphqlClient;
  StreamSubscription? _subscription;
  bool _messageDialogActive = false;
  
  bool phoneNumberNull = true;
  bool subscribedToMessages = false;
  bool callcheckAuthState = false;
  late FlutterLocalNotificationsPlugin _notificationsPlugin;

//////////////////////////////////////////////////////////////////////////////////////////////////
///Update Phone and Secret
Future<void> _loginFailedPrompt() async {

    Completer<void> promptsCompleter = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _showLocalNotification("Login Issue","Validate Credentials"); //show phone number
        await _showPhoneNumberDialog(); //prompt to update secret
        await _showRegistrationSecretDialog();
        if (_phoneNumber != null) _phoneNumber = '+1$_phoneNumber';
      promptsCompleter.complete();
      safePrint("PromptCompleted!");
    });
    await promptsCompleter.future;
  
}  

// SHOW MESSAGE NOTIFICATIONS ////////////////////////////////////////////////////////////////////////

  Future<void> _showLocalNotification(String title, String content) async {
    const androidDetails = AndroidNotificationDetails(
      'channel_id', 'Channel Name',
      channelDescription: 'Channel Description',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(0, title, content, details);
  }

/*   void _showLocalNotification(String title, String content) {
  _messageDialogActive = true;
  safePrint('Notification: $title - $content');
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('New Message', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Title: $title',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Content: $content',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  ).then((_) {
    setState(() {
          _messageDialogActive = false;
          });
      });
} */

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    safePrint('initState');
    final httpLink = HttpLink('https://pudgdftpfngldpdmnoyz637bgq.appsync-api.us-west-2.amazonaws.com/graphql'); 
    _graphqlClient = GraphQLClient(
      link: httpLink,
      cache: GraphQLCache(store: InMemoryStore()),
    );
    _initAsync();
    
  }

  Future<void> _initAsync() async {
    _notificationsPlugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _notificationsPlugin.initialize(initSettings);
    safePrint("Load Preferences 1");
    await _loadPreferences();  // Just load vars

    Completer<void> promptsCompleter = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_phoneNumber == null) await _showPhoneNumberDialog();
      if (_registrationSecret == null) await _showRegistrationSecretDialog();
      if (_phoneNumber != null) _phoneNumber = '+1$_phoneNumber';
      promptsCompleter.complete();
      safePrint("PromptCompleted!");
    });
    await promptsCompleter.future;

    safePrint("Initialize Database 3");
    await _initializeDatabase();  
    await _purgeOldMessages();

  // Wait for authentication; password reset may be required.
    Completer<void> authCompleter = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      safePrint("Check auth");
      await _checkAuthState();
      authCompleter.complete();
      });
    await authCompleter.future;

    if (_isAuthenticated && _phoneNumber != null) {
      await _fetchMissedMessages();
      _subscribeToMessages();
      safePrint('Subscribed to Message? TRUE');
    }
    safePrint('Initialize Background');
    await initializeBackgroundService();

  }


/////////////////////////////////////////////////////////////////////////////////////////////

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
    void didChangeAppLifecycleState(AppLifecycleState state) {
      super.didChangeAppLifecycleState(state);
      if (state == AppLifecycleState.resumed) {
        _loadMessages();  // Refresh messages when app resumes
      }
    }


/////////////////////////////////////////////////////////////////////////////////////////////
  Future<void> _checkAuthState() async {
    try {
      //final session = await Amplify.Auth.fetchAuthSession();
      final session = await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;      
      safePrint('Cognito Access Token: ${session.userPoolTokensResult}');
      //safePrint('Cognito Access Token: ${session.userPoolTokens?.accessToken}');
      if (_phoneNumber != null) {phoneNumberNull = false;
        if (session.isSignedIn) {
          setState(() {
            _isAuthenticated = true;
            safePrint('Phone Already Signed in - Auth check Success!!');
            //_showLocalNotification('_checkAuthState:','Phone Already Signed in - Auth check Success!!');
          });
        } else {
          safePrint('Not signed in, trying!');
          await _signInWithPhone();
        }
      }
    } catch (e) {
      safePrint('Auth check failed: $e');
      await _signInWithPhone();
    }
  }
/////////////////////////////////////////////////////////////////////////////////////////////
  Future<void> _signInWithPhone() async {
    try {
      String formattedPhone = '$_phoneNumber';
      safePrint('UnFormatted Phone: $_phoneNumber');
      safePrint('Secret: $_registrationSecret');
     
      final result = await Amplify.Auth.signIn(
        username: formattedPhone,
        password: _registrationSecret,  // Your temporary password
      );
      if (result.isSignedIn) {
        setState(() {
          _isAuthenticated = true;
          safePrint('Authenticated!');
        });

      } else if (result.nextStep.signInStep == AuthSignInStep.confirmSignInWithNewPassword) {
        safePrint('Temporary password detected - prompting for new password');
        //_showRegistrationSecretDialog();
        await _showNewPasswordDialog();  // Show dialog to set new password
      } else {
        safePrint('Sign in failed! Next step: ${result.nextStep.signInStep}');
        //await _loginFailedPrompt();
        //await _showLocalNotification("Login Issue","Validate Credentials and restart the app."); 
      }
    } catch (e) {
      safePrint('Sign in failed (Error Catch): $e');
      //await _loginFailedPrompt();
      //await _showLocalNotification("Login Issue","Validate Credentials and restart the app."); 
    }
  }

/////////////////////////////////////////////////////////////////////////////////////////////
  Future<void> _showNewPasswordDialog() async{
    final TextEditingController newPasswordController = TextEditingController();
    final TextEditingController confirmPasswordController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('A New Secret is required!'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: newPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New Secret',
                  hintText: 'Must include uppercase, lowercase, number, symbol (min 10 chars)',
                ),
              ),
              TextField(
                controller: confirmPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm New Secret',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final newPass = newPasswordController.text;
                final confirmPass = confirmPasswordController.text;
                if (newPass != confirmPass) {
                  safePrint('Secrets do not match');
                  return;
                }
                if (newPass.length < 10) {
                  safePrint('Secret too short');
                  return;
                }
                Navigator.pop(context);
                await _confirmNewPassword(newPass);  // Call the confirmation logic
                setState(() {
                  _registrationSecret = newPass; // Store Secret
                  _prefs.setString('registration_secret', _registrationSecret!);
                });
              },
              child: const Text('Submit'),
            ),
          ],
        );
      },
    );
  } 

/////////////////////////////////////////////////////////////////////////////////////////////
 Future<void> _confirmNewPassword(String newPassword) async {
  try {
    final confirmResult = await Amplify.Auth.confirmSignIn(
      confirmationValue: newPassword,
    );
    if (confirmResult.isSignedIn) {
      setState(() {
        _isAuthenticated = true;
        safePrint('New Secret set and authenticated!');
      });

    } else {
      safePrint('Confirm sign-in failed: ${confirmResult.nextStep.signInStep}');
    }
    } catch (e) {
      safePrint('Confirm sign-in error: $e');
    }
  }

//////////////////////////////////////////////////////////////////////////////////////////
StreamSubscription<GraphQLResponse<Message>>? subscription;

void _subscribeToMessages() {
  if (_phoneNumber != null) {
    const String subscriptionDoc = r'''
      subscription OnCreateMessage($phoneNumber: String!) {
        onCreateMessage(filter: {phoneNumber: {eq: $phoneNumber}}) {
          id
          phoneNumber
          sourceName
          title
          content
          timestamp
          isViewed
        }
      }
    ''';

    final subscriptionRequest = GraphQLRequest<String>(
      document: subscriptionDoc,
      variables: {'phoneNumber': _phoneNumber},
      decodePath: 'onCreateMessage',
    );

    final Stream<GraphQLResponse<String>> operation = Amplify.API.subscribe(
      subscriptionRequest,
      onEstablished: () => {
        safePrint('Subscription established for phone: $_phoneNumber'), 
        subscribedToMessages = true,
        isSubscriptionActive = true},
    );

    _subscription = operation.listen(
      (event) {
        if (event.data != null) {
          final newMessage = event.data!;  // If using modelType, it's already decoded to Message
          
          final jsonMap = json.decode(newMessage) as Map<String, dynamic>;
          final inner = jsonMap['onCreateMessage'] as Map<String, dynamic>;
          final theMessage = Message(
            id: inner['id'] as String,
            sourceName: inner['sourceName'] as String,
            title: inner['title'] as String,
            content: inner['content'] as String,
            timestamp: DateTime.parse(inner['timestamp'] as String),
            isViewed: inner['isViewed'] as bool,
            );
              
          safePrint(theMessage); //Coding & Debuging Step
          //newMessage should be a Json string and will need to be parse and setup to add new message
         
          if (_database != null) {
            try {
              _database!.insert('messages', theMessage.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
              safePrint('Foreground: Message persisted');
              _updateMessageInDynamoDB(theMessage.id);
            } catch (e) {
              safePrint('Foreground: Message insert failed: $e');
            }
          }
          _loadMessages();

        }
      },
      onError: (Object error) {
        safePrint('Subscription error: $error');
        isSubscriptionActive = false;  // Reset flag on error
        subscription?.cancel();
        subscription = null;
      },
    );
    subscribedToMessages = true;
    safePrint('Subscribed to messages for phone: $_phoneNumber');
  }
}
////////////////////////////////////////////////////////////////////////////////////////////////////
  // Load saved preferences
  Future<void> _loadPreferences() async{
    safePrint('Loading Preferences');
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _phoneNumber = _prefs.getString('phone_number');
      _messageRetentionDays = _prefs.getInt('message_retention_days');
      _registrationSecret = _prefs.getString('registration_secret');
    });
    
  }


////////////////////////////////////////////////////////////////////////////////////////////////////
// Initialize database and load messages
  Future<void> _initializeDatabase() async {
    safePrint('Initializing Local Database');
    _database = await openDatabase(
      path.join(await getDatabasesPath(), 'comms_database.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, dynamo_id TEXT UNIQUE, sourceName TEXT, title TEXT, content TEXT, timestamp TEXT, isViewed INTEGER)',
        );
        // Insert initial sample data
        // Insert initial sample data
          await db.insert('messages', {
            'dynamo_id': 'sample1',
            'sourceName': 'Device 1',
            'title': 'Maintenance Needed',
            'content': 'Endpoint device 1 requires urgent maintenance.',
            'timestamp': DateTime(2025, 8, 6, 21, 58).toIso8601String(),
            'isViewed': 0,
          });
          await db.insert('messages', {
            'dynamo_id': 'sample2',
            'sourceName': 'Device 2',
            'title': 'Low Battery',
            'content': 'Battery level critical on endpoint device 2.',
            'timestamp': DateTime(2025, 8, 7, 20, 30).toIso8601String(),
            'isViewed': 1,
          });
          await db.insert('messages', {
            'dynamo_id': 'sample3',
            'sourceName': 'Device 3',
            'title': 'Connectivity Issue',
            'content': 'Device 3 lost connection at 10:30 AM.',
            'timestamp': DateTime(2025, 8, 7, 10, 30).toIso8601String(),
            'isViewed': 0,
          });
          await db.insert('messages', {
            'dynamo_id': 'sample4',
            'sourceName': 'Device 14',
            'title': 'Maintenance Needed',
            'content': 'Endpoint device 1 requires urgent maintenance.',
            'timestamp': DateTime(2025, 8, 7, 21, 58).toIso8601String(),
            'isViewed': 0,
          });
          await db.insert('messages', {
            'dynamo_id': 'sample5',
            'sourceName': 'Device 3',
            'title': 'Low Battery',
            'content': 'Battery level critical on endpoint device 2.',
            'timestamp': DateTime(2025, 8, 7, 20, 30).toIso8601String(),
            'isViewed': 1,
          });
          await db.insert('messages', {
            'dynamo_id': 'sample6',
            'sourceName': 'Device 1',
            'title': 'Connectivity Issue',
            'content': 'Lost connection at 10:30 AM.',
            'timestamp': DateTime(2025, 8, 7, 10, 30).toIso8601String(),
            'isViewed': 0,
        });
      },
    );
    _loadMessages(); // Load messages into _messages list
  }
////////////////////////////////////////////////////////////////////////////////////////////////////
// Load messages from database
  Future<void> _loadMessages() async {
    safePrint('Loading Local Messages');
    final List<Map<String, dynamic>> maps = await _database!.query('messages', orderBy: 'timestamp DESC');
    setState(() {
      _messages = maps.map((map) => Message.fromMap(map)).toList();
    });
  }
////////////////////////////////////////////////////////////////////////////////////////////////////
  // Function to purge old messages
  Future<void> _purgeOldMessages() async {
      if (_messageRetentionDays != null && _database != null) {
        final threshold = DateTime.now().subtract(Duration(days: _messageRetentionDays!));
        await _database!.delete(
          'messages',
          where: 'timestamp < ?',
          whereArgs: [threshold.toIso8601String()],
        );
        _loadMessages(); // Refresh the message list after purge
      }
  }


////////////////////////////////////////////////////////////////////////////////////////////////////
// Fetch missed messages from DynamoDB
  Future<void> _fetchMissedMessages() async {
    if (_database == null) return;

    const String queryDoc = r'''
      query ListMissedMessages($phoneNumber: String!) {
        listMessages(filter: {phoneNumber: {eq: $phoneNumber}, isViewed: {eq: false}}) {
          items {
            id
            phoneNumber
            sourceName
            title
            content
            timestamp
            isViewed
          }
        }
      }
    ''';

    final request = GraphQLRequest<String>(
      document: queryDoc,
      variables: {'phoneNumber': _phoneNumber},
    );

    try {
      final response = await Amplify.API.query(request: request).response;
      if (response.errors.isNotEmpty) {
        safePrint('Query errors: ${response.errors}');
        return;
      }
      if (response.data == null) {
        safePrint('No data');
        return;
      }
      final data = json.decode(response.data!) as Map<String, dynamic>;
      final items = data['listMessages']?['items'] as List<dynamic>? ?? [];
      for (var item in items) {
        final inner = item as Map<String, dynamic>;
        final message = Message(
          id: inner['id'] as String,
          sourceName: inner['sourceName'] as String,
          title: inner['title'] as String,
          content: inner['content'] as String,
          timestamp: DateTime.parse(inner['timestamp'] as String),
          isViewed: inner['isViewed'] as bool,
        );

        await _showLocalNotification(message.title, message.content);

        await _database!.insert('messages', message.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
        await _updateMessageInDynamoDB(message.id);
      }
      await _loadMessages();
    } catch (e) {
      safePrint('Fetch missed failed: $e');
    }
  }


////////////////////////////////////////////////////////////////////////////////////////////////////
// Add a new message to the database and update the UI
/* Future<void> _addMessage(Message message) async {
  safePrint('Adding Messages to local database');
 
  if (_database != null) {
    //await _database!.insert('messages', message.toMap());
    await _loadMessages();
    
  }
} */
//////////////////////////////////////////////////////////////////////////////////////////////////
// Function to show phone number input dialog
Future<void> _showPhoneNumberDialog() async {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Update Phone Number',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Phone Number (e.g., XXXYYYZZZZ)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.phone,
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter a phone number';
              }
              final regExp = RegExp(r'^\d{10}$');
              if (!regExp.hasMatch(value)) {
                return 'Enter a valid US phone number (e.g., XXXYYYZZZZ)';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                setState(() {
                  _phoneNumber = controller.text; // Store phone number
                  _prefs.setString('phone_number', _phoneNumber!);
                });
                Navigator.pop(context);
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }

//////////////////////////////////////////////////////////////////////////////////////////////////
// Function to show message secret input dialog
Future<void> _showRegistrationSecretDialog() async {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Enter Message Registration Secret',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),),
        content: Form(
          key: formKey,
          child: TextFormField(
                  controller: controller,
                  obscureText: true, // Masks input
                  decoration: const InputDecoration(
                    labelText: 'Registration Secret: ',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter the secret';
                    }
                    final regExp = RegExp(r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[!@#$%^&*(),.?":{}|<>]).{10,}$');
                    if (!regExp.hasMatch(value)) {
                      return 'Must be 10+ chars with upper/lower, number, special char';
                    }
                    return null;
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                setState(() {
                  _registrationSecret = controller.text; // Store Secret
                  _prefs.setString('registration_secret', _registrationSecret!);
                });
                Navigator.pop(context);
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////


// In _MyHomePageState class

// Add this method for registration dialog and sign-up
Future<void> _registerApplication() async {
  final formKey = GlobalKey<FormState>();
  final phoneController = TextEditingController();
  final emailController = TextEditingController();

  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Register New User'),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: phoneController,
              decoration: const InputDecoration(labelText: 'Phone Number (e.g., +1234567890)'),
              keyboardType: TextInputType.phone,
              validator: (value) {
                if (value == null || value.isEmpty || !value.startsWith('+')) {
                  return 'Enter a valid phone number starting with +';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email Address'),
              keyboardType: TextInputType.emailAddress,
              validator: (value) {
                if (value == null || value.isEmpty || !value.contains('@')) {
                  return 'Enter a valid email address';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            if (formKey.currentState!.validate()) {
              try {
                // Perform sign-up with phone as username and email as attribute
                final signUpResult = await Amplify.Auth.signUp(
                  username: phoneController.text,
                  password: _generateTemporaryPassword(),  // Generate a strong temp password (user will reset later)
                  options: SignUpOptions(
                    userAttributes: {
                      CognitoUserAttributeKey.email: emailController.text,
                    },
                  ),
                );

                if (signUpResult.nextStep.signUpStep == AuthSignUpStep.confirmSignUp) {
                  // Prompt for verification code sent to phone
                  await _showConfirmationDialog(phoneController.text);
                } else {
                  // Handle other steps if needed
                  safePrint('Registration complete');
                }
              } on AuthException catch (e) {
                safePrint('Registration failed: ${e.message}');
                // Show error dialog
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Error'),
                    content: Text(e.message),
                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                  ),
                );
              }
              Navigator.pop(context);
            }
          },
          child: const Text('Register'),
        ),
      ],
    ),
  );
}

// Helper to generate a strong temporary password (user will reset on first login)
String _generateTemporaryPassword() {
  // Implement a secure random password generator (e.g., 12+ chars with mix of types)
  // For example, using dart:math for randomness
  const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890!@#\$%';
  final random = Random.secure();
  return List.generate(12, (index) => chars[random.nextInt(chars.length)]).join();
}

// Dialog for confirmation code
Future<void> _showConfirmationDialog(String username) async {
  final codeController = TextEditingController();

  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Confirm Registration'),
      content: TextFormField(
        controller: codeController,
        decoration: const InputDecoration(labelText: 'Verification Code'),
        keyboardType: TextInputType.number,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            try {
              await Amplify.Auth.confirmSignUp(
                username: username,
                confirmationCode: codeController.text,
              );
              safePrint('User confirmed');
              // Optionally, sign in the user or navigate
            } on AuthException catch (e) {
              safePrint('Confirmation failed: ${e.message}');
              // Show error
            }
            Navigator.pop(context);
          },
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////
 // Function to show message retention input dialog
  void _showMessageRetentionDialog() {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Message Retention',style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Retention Days (e.g., 30)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter the number of days';
              }
              final number = int.tryParse(value);
              if (number == null || number <= 0) {
                return 'Enter a positive number';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                setState(() {
                  _messageRetentionDays = int.parse(controller.text); // Store retention days
                  _prefs.setInt('message_retention_days', _messageRetentionDays!);
                });
                Navigator.pop(context);
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }
////////////////////////////////////////////////////////////////////////////////////////////////////
 // Function to show settings dialog
 void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Settings',style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Phone Number: ${_phoneNumber ?? 'none'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Retention Period: ${_messageRetentionDays != null ? '$_messageRetentionDays days' : 'none'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
////////////////////////////////////////////////////////////////////////////////////////////////////
    // Helper method to get the database id for a message
  Future<int> _getMessageId(Message message) async {
      final List<Map<String, dynamic>> result = await _database!.query(
        'messages',
        columns: ['id'],
        where: 'sourceName = ? AND timestamp = ?',
        whereArgs: [message.sourceName, message.timestamp.toIso8601String()],
      );
      return result.isNotEmpty ? result.first['id'] as int : -1; // -1 if not found
  }
////////////////////////////////////////////////////////////////////////////////////////////////////
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
                actions: [
          PopupMenuButton<MenuOption>(
            onSelected: (value) async {
              switch (value) {
                case MenuOption.updatePhone:
                  _showPhoneNumberDialog();
                case MenuOption.messageRetention:
                  _showMessageRetentionDialog();
                case MenuOption.viewSettings:
                  _showSettingsDialog();
                case MenuOption.purgeOldMessages:
                  await _purgeOldMessages(); // Trigger purge
                case MenuOption.updateSecret:
                  await _showRegistrationSecretDialog();
                case MenuOption.registerApplication:
                  await _registerApplication();
                case MenuOption.getMissedMessages:
                  await _fetchMissedMessages();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: MenuOption.viewSettings,
                child: Text('View Settings'),
              ),const PopupMenuItem(
                value: MenuOption.updatePhone,
                child: Text('Update Phone Number'),
              ),
              const PopupMenuItem(
                value: MenuOption.messageRetention,
                child: Text('Message Retention'),
              ),
              const PopupMenuItem(
                value: MenuOption.purgeOldMessages,
                child: Text('Purge Old Messages'),
              ),
              const PopupMenuItem(
                value: MenuOption.updateSecret,
                child: Text('Update Secret'),
              ),
              const PopupMenuItem(
                value: MenuOption.registerApplication,
                child: Text('Register App')
              ),
              const PopupMenuItem(
                value: MenuOption.getMissedMessages,
                child: Text('Retrive Messages')
              ),
              
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                         Text(
                         'Messages',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                             fontWeight: FontWeight.bold,
                             color: Theme.of(context).colorScheme.primary,
                             ),
                         ),
                          Row(
                            children: [
                                Text(
                                    'Show Unread Only',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: Theme.of(context).colorScheme.primary,              
                                        ),
                                    ),
                            const SizedBox(width: 8),
                            Switch(
                              value: _showUnreadOnly,
                              onChanged:(value) {
                                setState(() {_showUnreadOnly = value;
                                });
                              },
                              activeColor: Theme.of(context).colorScheme.primary,
                              ),
                            ],
                 ),
            
            ],
            ),
            const SizedBox(height: 8),
            // Message list
            Expanded(
              child: ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  if (_showUnreadOnly && message.isViewed) {
                    return const SizedBox.shrink();

                  }
                  return ListTile(
                    title: Text(
                      message.title,
                      style: TextStyle(
                        fontWeight: message.isViewed ? FontWeight.normal : FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      '${message.sourceName} - ${_dateFormat.format(message.timestamp)}',
                        style: Theme.of(context).textTheme.bodySmall,
                    ),
                      onTap: () async {
                        try {
                        if (_selectedMessage != message) {
                          if (_selectedMessage != null) {
                            final lastId = await _getMessageId(_selectedMessage!);
                            if (lastId != -1) {
                              await _database!.update(
                                'messages',
                                {'isViewed': 1},
                                where: 'id = ?',
                                whereArgs: [lastId],
                              );
                              // Update the in-memory message
                              final lastMessage = _messages.firstWhere((m) => m == _selectedMessage);
                              setState(() {
                                  lastMessage.isViewed = true;
                                });
                              
                            }
                          }
                          setState(() {
                            _selectedMessage = message; // Set new selection
                          });
                        }} catch (e) {safePrint(e);
                                      setState(() {
                                        _selectedMessage = message; // Set new selection
                                      }); 
                                      }
                      },
                    selected: _selectedMessage == message,
                    selectedTileColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                    //selectedTileColor: Theme.of(context).colorScheme.primary
                  );
                },
              ),
            ),
            const Divider(),
            // Selected message details
            Text(
              'Message Details',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _showUnreadOnly && (_selectedMessage?.isViewed ?? false)
                  ? const Center(child: Text('No unread messages selected'))
                  : _selectedMessage == null
                      ? const Center(child: Text('Select a message to view details'))
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Source: ${_selectedMessage!.sourceName}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Timestamp: ${_dateFormat.format(_selectedMessage!.timestamp)}',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _selectedMessage!.content,
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}