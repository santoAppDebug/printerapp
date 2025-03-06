// IppParserPlugin.kt
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import javax.mail.internet.MimeMultipart
import javax.mail.util.ByteArrayDataSource

class IppParserPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "ipp_parser")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    Log.d("IppParserPlugin", "Method call: ${call.method}, arguments: ${call.arguments}")
    if (call.method == "parseIpp") {
      val ippData = call.argument<ByteArray>("ippData")
      val printerUri = call.argument<String>("printerUri")
      if (ippData != null && printerUri != null) {
        CoroutineScope(Dispatchers.IO).launch {
          try {
            val (host, port, path) = parseIppUri(printerUri)
            Log.d("IppParserPlugin", "Parsed URI: host=$host, port=$port, path=$path")
            val url = URL("http", host, port, path)
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/ipp")
            connection.doOutput = true
            connection.outputStream.write(ippData)
            val statusCode = connection.responseCode
            Log.d("IppParserPlugin", "HTTP status code: $statusCode")
            if (statusCode == HttpURLConnection.HTTP_OK) {
              val inputStream = connection.inputStream
              val responseBody = readInputStream(inputStream)
              val pdfData = extractPdfData(responseBody)
              withContext(Dispatchers.Main) {
                result.success(pdfData)
              }
            } else {
              withContext(Dispatchers.Main) {
                result.error("HTTP_ERROR", "HTTP request failed: $statusCode", null)
              }
            }
            connection.disconnect()
          } catch (e: Exception) {
            Log.e("IppParserPlugin", "Error: ${e.message}", e)
            withContext(Dispatchers.Main) {
              result.error("IPP_PARSE_ERROR", e.message, null)
            }
          }
        }
      } else {
        result.error("IPP_DATA_NULL", "IPP data or printerUri is null", null)
      }
    } else {
      result.notImplemented()
    }
  }

  private fun readInputStream(inputStream: InputStream): ByteArray {
    val outputStream = ByteArrayOutputStream()
    val buffer = ByteArray(1024)
    var bytesRead: Int
    try {
      while (inputStream.read(buffer).also { bytesRead = it } != -1) {
        outputStream.write(buffer, 0, bytesRead)
      }
    } catch (e: IOException) {
      Log.e("IppParserPlugin", "Error reading input stream: ${e.message}", e)
    }
    return outputStream.toByteArray()
  }

  private fun extractPdfData(ippResponse: ByteArray): ByteArray {
    Log.d("IppParserPlugin", "extractPdfData called. ippResponse length: ${ippResponse.size}")
    try {
      val pdfAttribute = findPdfAttribute(ippResponse)
      if (pdfAttribute != null) {
        val pdfData = extractPdfDataFromAttribute(pdfAttribute)
        Log.d("IppParserPlugin", "PDF data extracted, length: ${pdfData.size}")
        return pdfData
      } else {
        Log.w("IppParserPlugin", "PDF attribute not found in IPP response")
        return ByteArray(0)
      }
    } catch (e: Exception) {
      Log.e("IppParserPlugin", "Error extracting PDF data: ${e.message}", e)
      return ByteArray(0)
    }
  }

  private fun findPdfAttribute(ippResponse: ByteArray): ByteArray? {
    Log.d("IppParserPlugin", "findPdfAttribute called (logging all attributes)")
    var index = 0
    while (index < ippResponse.size) {
      val attributeTag = ippResponse[index].toInt() and 0xFF
      index++
      if (attributeTag == 0x03) {
        Log.d("IppParserPlugin", "End of attributes reached.")
        break
      }
      if (index + 1 >= ippResponse.size) {
        Log.e("IppParserPlugin", "Unexpected end of data: attribute name length")
        return null
      }
      val nameLength = ((ippResponse[index].toInt() and 0xFF) shl 8) or (ippResponse[index + 1].toInt() and 0xFF)
      index += 2
      if (index + nameLength > ippResponse.size) {
        Log.e("IppParserPlugin", "Unexpected end of data: attribute name")
        return null
      }
      val attributeName = String(ippResponse.copyOfRange(index, index + nameLength))
      index += nameLength
      if (index + 1 >= ippResponse.size) {
        Log.e("IppParserPlugin", "Unexpected end of data: attribute value length")
        return null
      }
      val valueLength = ((ippResponse[index].toInt() and 0xFF) shl 8) or (ippResponse[index + 1].toInt() and 0xFF)
      index += 2
      Log.d("IppParserPlugin", "Attribute Tag: $attributeTag, Name: $attributeName, Value Length: $valueLength")
      val valuePreview = if (valueLength > 16) {
        ippResponse.copyOfRange(index, index + 16).joinToString("") { "%02X".format(it) } + "..."
      } else {
        ippResponse.copyOfRange(index, index + valueLength).joinToString("") { "%02X".format(it) }
      }
      Log.d("IppParserPlugin", "Attribute Value Preview: $valuePreview")
      if (attributeName == "job-data") { // Replace with the actual attribute name from Wireshark
        Log.d("IppParserPlugin", "PDF attribute found!")
        if (index + valueLength > ippResponse.size) {
          Log.e("IppParserPlugin", "Unexpected end of data: attribute value")
          return null
        }
        return ippResponse.copyOfRange(index, index + valueLength)
      }
      index += valueLength
    }
    Log.w("IppParserPlugin", "PDF attribute not found.")
    return null
  }

  private fun extractPdfDataFromAttribute(pdfAttribute: ByteArray): ByteArray {
    Log.d("IppParserPlugin", "extractPdfDataFromAttribute called, length: ${pdfAttribute.size}")
    try {
      val mimeMultipart = MimeMultipart(ByteArrayDataSource(pdfAttribute, "multipart/mixed"))
      for (i in 0 until mimeMultipart.count) {
        val bodyPart = mimeMultipart.getBodyPart(i)
        if (bodyPart.contentType.startsWith("application/pdf")) {
          val inputStream = bodyPart.inputStream
          return readInputStream(inputStream)
        }
      }
    } catch (e: Exception) {
      Log.e("IppParserPlugin", "Error parsing MIME data: ${e.message}", e)
    }
    return ByteArray(0)
  }

  private fun parseIppUri(ippUri: String): Triple<String, Int, String> {
    return try {
      val uri = ippUri.replace("ipp://", "")
      val parts = uri.split("/")
      val hostAndPort = parts[0].split(":")
      val host = hostAndPort[0]
      val port = if (hostAndPort.size > 1) hostAndPort[1].toInt() else 631
      val path = "/" + parts.subList(1, parts.size).joinToString("/")
      Triple(host, port, path)
    } catch (e: Exception) {
      Log.e("IppParserPlugin", "Error parsing IPP URI: ${e.message}")
      throw e
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
