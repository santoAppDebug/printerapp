import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:path_provider/path_provider.dart';

const int IPP_TAG_END_OF_ATTRIBUTES = 0x03;
const int IPP_OPERATION_PRINT_JOB = 0x0002;
const int IPP_OPERATION_GET_PRINTER_ATTRIBUTES = 0x000B;

// IPP Response Tags
class IppTag {
  static const OPERATION_ATTRIBUTES_TAG = 0x01;
  static const PRINTER_ATTRIBUTES_TAG = 0x04;
  static const END_OF_ATTRIBUTES = 0x03;
}

Uint8List uint16Bytes(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);
Uint8List uint32Bytes(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

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
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

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
  bool _hasDisplayedJob = false;

  String? _pdfPath;
  bool _isPdfLoaded = false;
  static HttpServer? _server;
  final Box _serviceBox = Hive.box('serviceBox');
  final Connectivity _connectivity = Connectivity();

  @override
  void initState() {
    super.initState();
    bool wasRunning = _serviceBox.get('isServiceRunning', defaultValue: false);
    if (wasRunning) startBonjourService();
    _startHttpServer();

    _connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      if (result == ConnectivityResult.wifi && !_isServiceRunning) {
        startBonjourService();
      }
    });
  }

  @override
  void dispose() {
    _server?.close();
    super.dispose();
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

  Future<String> _getLocalIP() async {
    final interfaces = await NetworkInterface.list();
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          return addr.address;
        }
      }
    }
    return 'localhost'; // Fallback if no IP found
  }

  Future<void> startBonjourService() async {
    if (_isServiceRunning) return;
    await stopBonjourService(); // Cleanup previous instance

    final localIP = await _getLocalIP();
    print(localIP);
    _serviceBox.put('localIP', localIP); // Store in Hi
    final service = BonsoirService(
      name: 'Flutter Printer',
      type: '_ipp._tcp',
      port: 8080,
      attributes: {
        // AirPrint mandatory fields
        'txtvers': '1',
        'adminurl': 'http://${localIP}:8080',
        'note': 'Flutter Printer',
        'pdl': 'application/pdf,image/urf',
        'product': '(Flutter AirPrint)',
        'printer-type': '0x0480FFFC', // Magic number for AirPrint
        'printer-state': '3', // 3 = idle
        'URF': 'W8,SRGB24,CP1,RS600', // Apple Raster capabilities
        'rp': 'ipp/print', // Must match your URI path
        'qtotal': '1',
        'usb_MFG': 'Flutter',
        'usb_MDL': 'AirPrint',
      },
    );

    _bonsoirBroadcast = BonsoirBroadcast(service: service);

    try {
      // Add these 2 critical lines
      await _bonsoirBroadcast!
          .ready; // Wait for platform channel initialization
      await _bonsoirBroadcast!.start();

      setState(() => _isServiceRunning = true);
      _serviceBox.put('isServiceRunning', true);
    } catch (error) {
      print("Bonsoir start failed: $error");
      _bonsoirBroadcast = null;
    }
  }

  Future<void> stopBonjourService() async {
    await _bonsoirBroadcast?.stop();
    _bonsoirBroadcast = null;
    setState(() => _isServiceRunning = false);
    _serviceBox.put('isServiceRunning', false);
    print("🔕 Bonjour service stopped.");
  }

  // HTTP server: listens for incoming IPP requests
  Future<void> _startHttpServer() async {
    await _server?.close();
    _server = null;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      print("Server running on port 8080");
      // The server enters an infinite loop to process incoming IPP requests.
      await for (HttpRequest request in _server!) {
        request.response.headers.chunkedTransferEncoding = false;
        print("Received request on path: ${request.uri}");
        try {
          final data = await _readFullRequest(request);
          final responseBytes =
              await _processIppRequest(data, request.response);

          if (responseBytes != null) {
            request.response
              ..headers.contentType = ContentType("application", "ipp")
              ..statusCode = HttpStatus.ok
              ..contentLength = responseBytes.length // Add content length
              ..add(responseBytes);
          }

          await request.response.close(); // 👈 Explicit close
        } catch (e) {
          print("Request error: $e");
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close(); // 👈 Close even on errors
        }
      }
    } catch (e) {
      print("💥 Server error: $e");
    }
  }

  Future<Uint8List> _readFullRequest(HttpRequest request) async {
    return await request
        .fold<BytesBuilder>(
          BytesBuilder(),
          (bb, data) => bb..add(data),
        )
        .then((bb) => bb.takeBytes());
  }

  Future<Uint8List?> _processIppRequest(
      Uint8List data, HttpResponse response) async {
    try {
      print("📦 Raw IPP header: ${data.sublist(0, 8)}"); // First 8 bytes
      final parser = IppParser(data);
      final hexOpId = parser.operationId.toRadixString(16).padLeft(4, '0');
      print("🔄 Operation ID: 0x$hexOpId (${parser.operationId})");

      switch (parser.operationId) {
        case IPP_OPERATION_GET_PRINTER_ATTRIBUTES:
          print("ℹ️ Handling Get-Printer-Attributes");
          return _handlePrinterAttributes(response);
        case IPP_OPERATION_PRINT_JOB:
          print("🖨️ Handling Print-Job request");
          return await _handlePrintJob(parser, response);
        default:
          print("⚠️ Unsupported operation: 0x$hexOpId");
          _sendIppError(response, 0x0501, "Unsupported operation");
          return null;
      }
    } catch (e, stack) {
      print("💥 Processing error: $e\n$stack");
      _sendIppError(response, 0x0400, "Invalid request");
      return null;
    }
  }

  Uint8List _handlePrinterAttributes(HttpResponse response) {
    final localIP = _serviceBox.get('localIP', defaultValue: 'localhost');
    print(localIP);
    final builder = IppResponseBuilder()
      ..setVersion(1, 1)
      ..setStatusCode(0x0000) // Success
      ..setRequestId(1)
      ..addIntegerList(
        'operations-supported',
        [IPP_OPERATION_PRINT_JOB, IPP_OPERATION_GET_PRINTER_ATTRIBUTES],
      )
      ..addAttributeGroup(IppTag.OPERATION_ATTRIBUTES_TAG)
      ..addString('attributes-charset', 'utf-8')
      ..addString('attributes-natural-language', 'en-us')
      ..addAttributeGroup(IppTag.PRINTER_ATTRIBUTES_TAG)
      ..addString('printer-name', 'Flutter Printer')
      ..addString('printer-uri-supported',
          'ipp://$localIP:8080/ipp/print') // Must match Bonjour "rp"
      ..addStringList('document-format-supported', ['application/pdf'])
      ..addString('uri-security-supported', 'none')
      ..addString(
          'printer-state', 'idle') // Must be "idle", "processing", or "stopped"
      ..addString('printer-state-reasons', 'none')
      ..addBoolean('printer-is-accepting-jobs', true);

    return builder.build();
  }

// Helper to convert operation names to IPP codes

  void _sendIppError(HttpResponse response, int code, String message) {
    final builder = IppResponseBuilder()
      ..setVersion(1, 1)
      ..setStatusCode(code)
      ..setRequestId(1)
      ..addAttributeGroup(IppTag.OPERATION_ATTRIBUTES_TAG)
      ..addString('status-message', message);

    response.statusCode = HttpStatus.ok;
    response.add(builder.build());
  }

  Future<Uint8List?> _handlePrintJob(
      IppParser parser, HttpResponse response) async {
    try {
      final pdfData = parser.getDocumentData();
      if (pdfData == null || !_validatePdf(pdfData)) {
        _sendIppError(response, 0x0400, "Invalid PDF data");
        return null;
      }

      await _savePdf(pdfData);
      _displayPdf(pdfData);

      final builder = IppResponseBuilder()
        ..setVersion(1, 1)
        ..setStatusCode(0x0000)
        ..setRequestId(1)
        ..addAttributeGroup(IppTag.OPERATION_ATTRIBUTES_TAG)
        ..addString('job-id', '1234')
        ..addString('job-uri', 'ipp://localhost:8080/jobs/1234');

      return builder.build();
    } catch (e) {
      _sendIppError(response, 0x0500, "Print job failed");
      return null;
    }
  }

  void _displayPdf(Uint8List pdfData) {
    if (context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PdfViewerScreen(pdfBytes: pdfData),
        ),
      );
    }
  }

  bool _validatePdf(Uint8List data) {
    if (data.length < 4) return false;
    return data[0] == 0x25 && // %
        data[1] == 0x50 && // P
        data[2] == 0x44 && // D
        data[3] == 0x46; // F
  }

  Future<void> _savePdf(Uint8List data) async {
    final dir = await getApplicationDocumentsDirectory();
    final file =
        File('${dir.path}/print_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await file.writeAsBytes(data);
    print("PDF saved to ${file.path}");
  }

  void handlePrint() {
    // Stub for any additional print-triggered actions.
    print("handlePrint called.");
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

class IppResponseBuilder {
  final BytesBuilder _buffer = BytesBuilder();
  int _currentGroup = 0x00;

  IppResponseBuilder setVersion(int major, int minor) {
    _buffer.addByte(major);
    _buffer.addByte(minor);
    return this;
  }

  IppResponseBuilder setStatusCode(int code) {
    _buffer.add(uint16Bytes(code));
    return this;
  }

  IppResponseBuilder setRequestId(int id) {
    _buffer.add(uint32Bytes(id));
    return this;
  }

  IppResponseBuilder addAttributeGroup(int tag) {
    _buffer.addByte(tag);
    _currentGroup = tag;
    return this;
  }

  IppResponseBuilder addString(String name, String value) {
    _addAttributeHeader(name, 0x47);
    _buffer.add(uint16Bytes(value.length));
    _buffer.add(value.codeUnits);
    return this;
  }

  IppResponseBuilder addStringList(String name, List<String> values) {
    for (final value in values) {
      _addAttributeHeader(name, 0x47);
      _buffer.add(uint16Bytes(value.length));
      _buffer.add(value.codeUnits);
    }
    return this;
  }

  IppResponseBuilder addBoolean(String name, bool value) {
    _addAttributeHeader(name, 0x22);
    _buffer.addByte(value ? 0x01 : 0x00);
    return this;
  }

  void _addAttributeHeader(String name, int tag) {
    _buffer.addByte(0x42); // Keyword tag for attribute name.
    _buffer.add(uint16Bytes(name.length));
    _buffer.add(name.codeUnits);
    _buffer.addByte(tag);
  }

  IppResponseBuilder addIntegerList(String name, List<int> values) {
    for (final value in values) {
      _addAttributeHeader(name, 0x23); // Integer type
      _buffer.add(uint32Bytes(value));
    }
    return this;
  }

  Uint8List build() {
    _buffer.addByte(IppTag.END_OF_ATTRIBUTES);
    return _buffer.toBytes();
  }
}

class IppParser {
  final Uint8List _data;
  int _offset = 0;

  IppParser(Uint8List bytes) : _data = bytes;
  int get operationId {
    // Bytes 2-3: Operation ID (big-endian)
    return (_data[2] << 8) | _data[3];

    // Was previously using wrong offset
  }

  Uint8List? getDocumentData() {
    _offset = 8; // Skip version (2), operation (2), request-id (4)

    while (_offset < _data.length - 1) {
      final tag = _data[_offset++];

      if (tag == IPP_TAG_END_OF_ATTRIBUTES) {
        print("✅ Found end-of-attributes at offset $_offset");
        return _data.sublist(_offset + 1); // Return remaining bytes as PDF
      }

      if (tag >= 0x01 && tag <= 0x04) {
        print("⚙️ Skipping attribute group tag: 0x${tag.toRadixString(16)}");
        continue;
      }

      // Read attribute name
      final nameLength = _readUint16(_offset);
      _offset += 2;
      final name =
          String.fromCharCodes(_data.sublist(_offset, _offset + nameLength));
      _offset += nameLength;

      // Read value tag and value
      final valueTag = _data[_offset++];
      final valueLength = _readUint16(_offset);
      _offset += 2;
      _offset += valueLength; // Skip value bytes

      print(
          "🔍 Attribute: $name (tag: 0x${valueTag.toRadixString(16)}, length: $valueLength)");
    }

    print("⚠️ Reached end of data without finding PDF content");
    return null;
  }

  int _readUint16(int offset) {
    return (_data[offset] << 8) | _data[offset + 1];
  }
}
