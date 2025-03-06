import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('serviceBox');
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final FocusNode _focusNode = FocusNode();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Print Service',
      theme: ThemeData(primarySwatch: Colors.blue),
      debugShowCheckedModeBanner: false,
      home: Focus(
        autofocus: true,
        child: RawKeyboardListener(
          focusNode: _focusNode,
          onKey: (RawKeyEvent event) {
            if (event is RawKeyDownEvent) {
              print("🔑 Key Pressed: ${event.logicalKey}");

              bool isMac = Platform.isMacOS;
              bool isWindows = Platform.isWindows || Platform.isLinux;
              bool isMetaPressed = isMac && event.isMetaPressed;
              bool isCtrlPressed = isWindows && event.isControlPressed;
              bool isPKey = event.logicalKey == LogicalKeyboardKey.keyP;

              if ((isMac && isMetaPressed && isPKey) ||
                  (isWindows && isCtrlPressed && isPKey)) {
                print("🖨️ Print Triggered!");
                _triggerPrint(context);
              }
            }
          },
          child: PrintServiceScreen(),
        ),
      ),
    );
  }

  void _triggerPrint(BuildContext context) {
    print("📢 Print function called!");
    PrintServiceScreen.handlePrint(context);
  }
}

class PrintServiceScreen extends StatefulWidget {
  const PrintServiceScreen({super.key});

  @override
  _PrintServiceScreenState createState() => _PrintServiceScreenState();

  static void handlePrint(BuildContext context) {
    final state = context.findAncestorStateOfType<_PrintServiceScreenState>();
    if (state != null) {
      state.handlePrint();
    } else {
      print("⚠️ Could not find PrintServiceScreen state!");
    }
  }
}

class _PrintServiceScreenState extends State<PrintServiceScreen> {
  static BonsoirBroadcast? _bonsoirBroadcast;
  bool _isServiceRunning = false;
  Uint8List? _pdfData;
  static HttpServer? _server;
  final Box _serviceBox = Hive.box('serviceBox');
  final Connectivity _connectivity = Connectivity();

  @override
  void initState() {
    super.initState();
    bool wasRunning = _serviceBox.get('isServiceRunning', defaultValue: false);
    if (wasRunning) startBonjourService();
    startHttpServer();

    _connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      if (result == ConnectivityResult.wifi) {
        if (!_isServiceRunning) {
          startBonjourService();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Print Service")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _isServiceRunning ? "Service is Running" : "Service is Stopped",
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                if (_isServiceRunning) {
                  stopBonjourService();
                } else {
                  startBonjourService();
                }
              },
              child: Text(_isServiceRunning ? "Stop Service" : "Start Service"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> startBonjourService() async {
    if (_isServiceRunning) return;
    await stopBonjourService();

    _bonsoirBroadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: 'FlutterPrintService',
        type: '_ipp._tcp',
        port: 8080,
      ),
    );

    try {
      await _bonsoirBroadcast!.ready;
      await _bonsoirBroadcast!.start();
      setState(() => _isServiceRunning = true);
      _serviceBox.put('isServiceRunning', true);
    } catch (error) {
      print("❌ Failed to start Bonjour service: $error");
    }
  }

  Future<void> stopBonjourService() async {
    await _bonsoirBroadcast?.stop();
    _bonsoirBroadcast = null;
    setState(() => _isServiceRunning = false);
    _serviceBox.put('isServiceRunning', false);
  }

  Future<void> startHttpServer() async {
    await _server?.close();
    _server = null;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      print("🖨️ HTTP Server Running on Port 8080");

      await for (HttpRequest request in _server!) {
        print("📥 Received Request: ${request.method} at ${request.uri.path}");

        if (request.method == 'POST') {
          print("📩 Handling POST request...");
          Uint8List ippData = await receivePdfData(request);
          // debugIppData(ippData);

          if (ippData.isEmpty) {
            print("❌ No data received in IPP request!");
            request.response
              ..statusCode = HttpStatus.badRequest
              ..write('❌ No IPP data received!')
              ..close();
            continue;
          }

          // Attempt to process IPP data
          try {
            saveIPPDocument(ippData);
            print("✅ Successfully extracted document from IPP request.");
          } catch (error) {
            print("❌ Error processing IPP request: $error");
          }
        } else {
          print("🔹 Non-POST request received: ${request.method}");
        }
      }
    } catch (e) {
      print("❌ Error starting HTTP server: $e");
    }
  }

  Future<Uint8List> receivePdfData(HttpRequest request) async {
    List<int> receivedData = [];
    await for (var data in request) {
      receivedData.addAll(data);
    }
    return Uint8List.fromList(receivedData);
  }

  Future<void> saveIPPDocument(Uint8List ippData) async {
    print("📥 Received IPP Data: ${ippData.length} bytes");

    // Identify the correct start of document
    int docStartIndex = findDocumentStartIndex(ippData);
    if (docStartIndex == -1 || docStartIndex >= ippData.length - 1) {
      print("❌ No valid document data found in the IPP request!");
      return;
    }

    // Extract document bytes
    Uint8List documentData = ippData.sublist(docStartIndex);
    if (documentData.isEmpty) {
      print("❌ Document data is empty after IPP headers!");
      return;
    }

    print("✅ Extracted Document Data: ${documentData.length} bytes");

    try {
      // Request permissions
      if (Platform.isAndroid) {
        var status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          print("❌ Storage permission denied!");
          return;
        }
      }

      // Set file save directory
      Directory? directory;
      if (Platform.isAndroid) {
        directory = Directory(
            "/storage/emulated/0/Download"); // ✅ Save in Downloads folder
      } else {
        directory = await getApplicationDocumentsDirectory(); // iOS alternative
      }

      if (!directory.existsSync()) {
        print("❌ Storage directory not found!");
        return;
      }

      // Generate unique filename
      String filePath =
          "${directory.path}/printed_document_${DateTime.now().millisecondsSinceEpoch}.pdf";

      // Write file
      File file = File(filePath);
      await file.writeAsBytes(documentData);

      print("📂 Document saved at: $filePath");
    } catch (e) {
      print("❌ Error saving document: $e");
    }
  }

// Function to identify correct start index

  int findDocumentStartIndex(Uint8List ippData) {
    int minDocumentSize = 100; // A rough threshold for skipping small headers

    for (int i = 0; i < ippData.length - minDocumentSize; i++) {
      // If we detect a big jump in values (possible start of binary document)
      if (ippData[i] == 0x00 && ippData[i + 1] > 0x10) {
        return i + 1; // Start from the next byte
      }
    }

    return -1; // If no valid document start is found
  }

// void debugIppData(Uint8List ippData) {
//   print("📥 Debugging IPP Data Length: ${ippData.length} bytes");

//   // Print first 50 bytes (adjust if needed)
//   int lengthToPrint = ippData.length < 50 ? ippData.length : 50;
//   print("🔍 First $lengthToPrint bytes: ${ippData.sublist(0, lengthToPrint)}");

//   int pdfStartIndex = ippData.indexOf(0x25); // '%' = 0x25 (PDF signature)
//   if (pdfStartIndex != -1) {
//     print("📄 Found possible document data starting at index: $pdfStartIndex");
//   } else {
//     print("❌ No recognizable document data found!");
//   }
// }

  Future<String> convertToPDF(String inputFilePath) async {
    String outputFilePath =
        inputFilePath.replaceAll(RegExp(r"\.(ps|pcl)$"), ".pdf");

    try {
      if (inputFilePath.endsWith(".ps")) {
        await Process.run("gs", [
          "-dNOPAUSE",
          "-dBATCH",
          "-sDEVICE=pdfwrite",
          "-sOutputFile=$outputFilePath",
          inputFilePath
        ]);
      } else if (inputFilePath.endsWith(".pcl")) {
        await Process.run("pcl6", [
          "-sDEVICE=pdfwrite",
          "-sOutputFile=$outputFilePath",
          inputFilePath
        ]);
      }
      return outputFilePath;
    } catch (e) {
      print("❌ Conversion failed: $e");
      return "";
    }
  }

  void handlePrint() {
    if (_pdfData != null && _pdfData!.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PdfViewerScreen(pdfBytes: _pdfData!),
        ),
      );
    }
  }
}

class PdfViewerScreen extends StatelessWidget {
  final Uint8List pdfBytes;
  const PdfViewerScreen({super.key, required this.pdfBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PDF Viewer')),
      body: PDFView(pdfData: pdfBytes),
    );
  }
}
