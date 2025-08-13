import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'dart:async';

import 'amplify_outputs.dart'; // Generated from sandbox

void main() async {
  try {
      WidgetsFlutterBinding.ensureInitialized();
      await _configureAmplify();
      runApp(const MyApp());
      } on AmplifyException catch (e) {
           runApp(Text("Error configuring Amplify: ${e.message}"));
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
  final String sourceName;
  final String title;
  final String content;
  final DateTime timestamp; // New DateTime field
  bool isViewed;

  Message({
    required this.sourceName,
    required this.title,
    required this.content,
    required this.timestamp,
    this.isViewed = false,
  });

// Convert Message to Map for database
  Map<String, dynamic> toMap() {
    return {
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
      sourceName: map['sourceName'],
      title: map['title'],
      content: map['content'],
      timestamp: DateTime.parse(map['timestamp']),
      isViewed: map['isViewed'] == 1,
    );
  }
}

// Enum for menu options
enum MenuOption { viewSettings, updatePhone, messageRetention, purgeOldMessages }

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Database? _database;
  List<Message> _messages = [];
  Message? _selectedMessage;
  final DateFormat _dateFormat = DateFormat('MM/dd/yyyy HH:mm:ss');
  String? _phoneNumber;
  int? _messageRetentionDays;
  bool _showUnreadOnly = false;
  bool _isAuthenticated = false;
  late SharedPreferences _prefs;
  late GraphQLClient _graphqlClient;
  StreamSubscription? _subscription;

  // Show a local notification (placeholder implementation)
  void _showLocalNotification(String title, String content) {
    // You can integrate a notification package here, e.g., flutter_local_notifications.
    // For now, just print to console.
    safePrint('Notification: $title - $content');
  }

  @override
  void initState() {
    super.initState();
    
    final httpLink = HttpLink('https://your-api-endpoint/graphql'); // Replace with your API endpoint
    _graphqlClient = GraphQLClient(
      link: httpLink,
      cache: GraphQLCache(store: InMemoryStore()),
    );
    _checkAuthState();
    _loadPreferences();
    _initializeDatabase();
    if (_isAuthenticated && _phoneNumber != null) {
      _subscribeToMessages();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }


  Future<void> _checkAuthState() async {
    try {
      final session = await Amplify.Auth.fetchAuthSession();
      if (session.isSignedIn) {
        setState(() {
          _isAuthenticated = true;
        });
      } else {
        _signInWithPhone();
      }
    } catch (e) {
      safePrint('Auth check failed: $e');
      _signInWithPhone();
    }
  }

  Future<void> _signInWithPhone() async {
    try {
      String formattedPhone = '+1${_phoneNumber ?? '9402063925'}';
      safePrint('Formatted Phone: $formattedPhone');
      final result = await Amplify.Auth.signIn(
        username: formattedPhone,
        password: 'TestPass123!', // Replace with actual password or handle securely
      );
      if (result.isSignedIn) {
        setState(() {
          _isAuthenticated = true;
        });
        if (_phoneNumber != null) {
          _subscribeToMessages();
        }
      }
    } on AuthException catch (e) {
      safePrint('Sign in failed: $e');
    }
  }

 void _subscribeToMessages() {
    if (_phoneNumber != null) {
      try {
        _subscription = _graphqlClient.subscribe(
          SubscriptionOptions(
            document: gql(r'''
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
            '''),
            variables: {'phoneNumber': _phoneNumber},
          ),
        ).listen(
          (event) {
            final data = event.data?['onCreateMessage'];
            if (data != null) {
              final newMessage = Message.fromMap({
                'sourceName': data['sourceName'],
                'title': data['title'],
                'content': data['content'],
                'timestamp': data['timestamp'],
                'isViewed': data['isViewed'],
              });
              _addMessage(newMessage);
              _showLocalNotification(newMessage.title, newMessage.content);
            }
          },
          onError: (error) {
            safePrint('Subscription error: $error');
          },
        );
        safePrint('Subscribed to messages for phone: $_phoneNumber');
      } catch (e) {
        safePrint('Subscription setup failed: $e');
      }
    }
  }

  // Load saved preferences
  Future<void> _loadPreferences() async{
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _phoneNumber = _prefs.getString('phone_number');
      _messageRetentionDays = _prefs.getInt('message_retention_days');
    });
    _checkPhoneNumber();
    _initializeDatabase();
    await _purgeOldMessages();
  }

  // Check and prompt for phone number on first run
  void _checkPhoneNumber() {
    if (_phoneNumber == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showPhoneNumberDialog();
      });
    }
  }


// Initialize database and load messages
  Future<void> _initializeDatabase() async {
    _database = await openDatabase(
      path.join(await getDatabasesPath(), 'comms_database.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, sourceName TEXT, title TEXT, content TEXT, timestamp TEXT, isViewed INTEGER)',
        );
        // Insert initial sample data
        // Insert initial sample data
          await db.insert('messages', {
            'sourceName': 'Device 1',
            'title': 'Maintenance Needed',
            'content': 'Endpoint device 1 requires urgent maintenance.',
            'timestamp': DateTime(2025, 8, 6, 21, 58).toIso8601String(),
            'isViewed': 0,
          });
          await db.insert('messages', {
            'sourceName': 'Device 2',
            'title': 'Low Battery',
            'content': 'Battery level critical on endpoint device 2.',
            'timestamp': DateTime(2025, 8, 7, 20, 30).toIso8601String(),
            'isViewed': 1,
          });
          await db.insert('messages', {
            'sourceName': 'Device 3',
            'title': 'Connectivity Issue',
            'content': 'Device 3 lost connection at 10:30 AM.',
            'timestamp': DateTime(2025, 8, 7, 10, 30).toIso8601String(),
            'isViewed': 0,
          });
          await db.insert('messages', {
            'sourceName': 'Device 14',
            'title': 'Maintenance Needed',
            'content': 'Endpoint device 1 requires urgent maintenance.',
            'timestamp': DateTime(2025, 8, 7, 21, 58).toIso8601String(),
            'isViewed': 0,
          });
          await db.insert('messages', {
            'sourceName': 'Device 3',
            'title': 'Low Battery',
            'content': 'Battery level critical on endpoint device 2.',
            'timestamp': DateTime(2025, 8, 7, 20, 30).toIso8601String(),
            'isViewed': 1,
          });
          await db.insert('messages', {
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

// Load messages from database
  Future<void> _loadMessages() async {
    final List<Map<String, dynamic>> maps = await _database!.query('messages', orderBy: 'timestamp DESC');
    setState(() {
      _messages = maps.map((map) => Message.fromMap(map)).toList();
    });
  }

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

// Add a new message to the database and update the UI
Future<void> _addMessage(Message message) async {
  if (_database != null) {
    await _database!.insert('messages', message.toMap());
    await _loadMessages();
  }
}

// Function to show phone number input dialog
void _showPhoneNumberDialog() {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    showDialog(
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