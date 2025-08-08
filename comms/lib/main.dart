import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; 
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
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
  final String title;
  final String content;
  final DateTime timestamp; // New DateTime field
  bool isViewed;

  Message({
    required this.id,
    required this.title,
    required this.content,
    required this.timestamp,
    this.isViewed = false,
  });
}

// Enum for menu options
enum MenuOption { showSettings, updatePhone, messageRetention }

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  // Sample messages with DateTime (replace with AWS data, e.g., from DynamoDB)
  final List<Message> _messages = [
    Message(
      id: '1',
      title: 'Device 1: Maintenance Needed',
      content: 'Endpoint device 1 requires urgent maintenance.',
      timestamp: DateTime(2025, 8, 7, 21, 58), // Example timestamp
      isViewed: false,
    ),
    Message(
      id: '2',
      title: 'Device 2: Low Battery',
      content: 'Battery level critical on endpoint device 2.',
      timestamp: DateTime(2025, 8, 7, 20, 30),
      isViewed: true,
    ),
    Message(
      id: '3',
      title: 'Device 3: Connectivity Issue',
      content: 'Device 3 lost connection at 10:30 AM.',
      timestamp: DateTime(2025, 8, 7, 10, 30),
      isViewed: false,
    ),
    Message(
      id: '4',
      title: 'Device 4: Maintenance Needed',
      content: 'Endpoint device 1 requires urgent maintenance.',
      timestamp: DateTime(2025, 8, 7, 21, 58), // Example timestamp
      isViewed: false,
    ),
    Message(
      id: '5',
      title: 'Device 5: Low Battery',
      content: 'Battery level critical on endpoint device 2.',
      timestamp: DateTime(2025, 8, 7, 20, 30),
      isViewed: true,
    ),
    Message(
      id: '6',
      title: 'Device 6: Connectivity Issue',
      content: 'Device 3 lost connection at 10:30 AM.',
      timestamp: DateTime(2025, 8, 7, 10, 30),
      isViewed: false,
    ),
  ];

  // Track selected message
  Message? _selectedMessage;

  // DateTime formatter
  final DateFormat _dateFormat = DateFormat('MM/dd/yyyy HH:mm');

  // Phone number variable
  String? _phoneNumber;
    // Message retention variable
  int? _messageRetentionDays;

    // SharedPreferences instance
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _loadPreferences(); // Load saved values on app start
  }

  // Load saved preferences
  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _phoneNumber = _prefs.getString('phone_number');
      _messageRetentionDays = _prefs.getInt('message_retention_days');
    });
  }

// Function to show phone number input dialog
  void _showPhoneNumberDialog() {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update Phone Number'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Phone Number (e.g., +1XXXYYYZZZZ)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.phone,
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter a phone number';
              }
              final regExp = RegExp(r'^\+1\d{10}$');
              if (!regExp.hasMatch(value)) {
                return 'Enter a valid US phone number (e.g., +1XXXYYYZZZZ)';
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
        title: const Text('Message Retention'),
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
        title: const Text('Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Phone Number: ${_phoneNumber ?? 'none'}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Retention Period: ${_messageRetentionDays != null ? '$_messageRetentionDays days' : 'none'}',
              style: Theme.of(context).textTheme.bodyLarge,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
                actions: [
          PopupMenuButton<MenuOption>(
            onSelected: (value) {
              switch (value) {
                case MenuOption.updatePhone:
                  _showPhoneNumberDialog();
                case MenuOption.messageRetention:
                  _showMessageRetentionDialog();
                case MenuOption.showSettings:
                _showSettingsDialog();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: MenuOption.showSettings,
                child: Text('Show Settings'),
              ),const PopupMenuItem(
                value: MenuOption.updatePhone,
                child: Text('Update Phone Number'),
              ),
              const PopupMenuItem(
                value: MenuOption.messageRetention,
                child: Text('Message Retention'),
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
            // Messages row title
            Text(
              'Messages',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 8),
            // Message list
            Expanded(
              child: ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return ListTile(
                    title: Text(
                      message.title,
                      style: TextStyle(
                        fontWeight: message.isViewed ? FontWeight.normal : FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      _dateFormat.format(message.timestamp), // Formatted DateTime
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    onTap: () {
                      setState(() {
                        _selectedMessage = message;
                        message.isViewed = true; // Mark as viewed when selected
                      });
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
              child: _selectedMessage == null
                  ? const Center(child: Text('Select a message to view details'))
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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