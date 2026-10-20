package cn.edu.cumt.volunteer.admin_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipInputStream

/**
 * 名单导入：选一个 Excel / CSV 文件，把内容交给 Flutter 侧解析。
 *
 * ## 为什么要在原生侧做
 *
 * 项目里没有引入 `file_picker` / `excel` 这类插件（依赖刻意保持精简，
 * 服务端甚至是零 npm 依赖）。而"选文件"本质上只有原生能做；
 * .xlsx 又是个 zip，需要解压。
 *
 * 所以这里只做**两件不含业务逻辑的事**：
 *   1. 打开系统文件选择器，拿到文件；
 *   2. 如果是 xlsx（zip），把里面两个 XML 取出来。
 *
 * **真正的表格解析放在 Dart 侧**（`spreadsheet_import.dart`）——
 * 因为 Dart 能写成纯函数、能单测（用 openpyxl 生成的真实 XML 做夹具），
 * 而 Kotlin 侧在这个项目里没有测试基建。
 *
 * ## 为什么不支持老的 .xls
 *
 * `.xls` 是 OLE2 复合文档 + 私有二进制格式，解析量远大于 xlsx（zip + XML）。
 * 这里会明确告知"请另存为 .xlsx 或 CSV"，而不是给一个含糊的"读取失败"。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "volunteer/spreadsheet"
        private const val REQ_PICK = 4301

        // .xlsx = zip：首字节 'P' 'K'
        private val ZIP_MAGIC = byteArrayOf(0x50, 0x4B)
        // .xls = OLE2 复合文档：D0 CF 11 E0
        private val OLE2_MAGIC = byteArrayOf(0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte())
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickSpreadsheet" -> startPick(result)
                    else -> result.notImplemented()
                }
            }
    }

    /** 防止连点两次导致结果串台。 */
    private fun startPick(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "上一次选择还没结束", null)
            return
        }
        pendingResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf(
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        "application/vnd.ms-excel",
                        "text/csv",
                        "text/comma-separated-values",
                        "text/plain",
                        "application/octet-stream",
                    ),
                )
            }
            startActivityForResult(intent, REQ_PICK)
        } catch (e: Exception) {
            pendingResult = null
            result.error("NO_PICKER", "打不开文件选择器：${e.message}", null)
        }
    }

    @Deprecated("FlutterActivity 仍支持该回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK) {
            return
        }
        val result = pendingResult ?: return
        pendingResult = null

        // 用户取消不是错误：返回 null，让 Dart 侧安静处理。
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.success(null)
            return
        }

        try {
            result.success(extract(uri))
        } catch (e: Exception) {
            result.error("READ_FAILED", e.message ?: "读取文件失败", null)
        }
    }

    /** 读文件 → 判断类型 → 提取内容。 */
    private fun extract(uri: Uri): Map<String, Any?> {
        val name = displayNameOf(uri) ?: "unknown"
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("文件打不开")

        if (bytes.isEmpty()) {
            throw IllegalStateException("文件是空的")
        }

        if (startsWith(bytes, OLE2_MAGIC)) {
            throw UnsupportedOperationException(
                "不支持旧的 .xls 格式。请在 Excel 里另存为「.xlsx」或「CSV」再导入。",
            )
        }

        if (startsWith(bytes, ZIP_MAGIC)) {
            return extractXlsx(name, bytes)
        }

        // 其余按文本处理（CSV / TSV / TXT）。
        return mapOf(
            "kind" to "text",
            "name" to name,
            "text" to decodeText(bytes),
        )
    }

    /** xlsx = zip；取共享字符串表与第一个工作表。 */
    private fun extractXlsx(name: String, bytes: ByteArray): Map<String, Any?> {
        var sharedStrings: String? = null
        var sheet: String? = null
        var sheetName: String? = null

        ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                val path = entry.name
                when {
                    path == "xl/sharedStrings.xml" -> sharedStrings = zip.readCurrentText()
                    path.matches(Regex("xl/worksheets/sheet\\d+\\.xml")) && sheet == null -> {
                        sheet = zip.readCurrentText()
                        sheetName = path
                    }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }

        if (sheet == null) {
            throw IllegalStateException(
                "这个文件看起来不是 Excel 工作簿（没找到工作表）。请确认是 .xlsx。",
            )
        }

        return mapOf(
            "kind" to "xlsx",
            "name" to name,
            // 没有 sharedStrings 是合法的（全是数字或内联字符串）。
            "sharedStrings" to sharedStrings,
            "sheet" to sheet,
            "sheetPath" to sheetName,
        )
    }

    private fun ZipInputStream.readCurrentText(): String {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = read(buffer)
            if (n <= 0) break
            out.write(buffer, 0, n)
        }
        return out.toString("UTF-8")
    }

    /**
     * 文本解码：优先 UTF-8，出现替换字符再按 GBK 试。
     *
     * 国内用户从 Excel「另存为 CSV」拿到的是 **GBK** 编码，
     * 按 UTF-8 读会得到一堆乱码 —— 而乱码名单导入后每条都是错的，
     * 比直接报错更难排查。
     */
    private fun decodeText(bytes: ByteArray): String {
        val utf8 = String(bytes, Charsets.UTF_8)
        if (!utf8.contains('\uFFFD')) {
            return utf8
        }
        return try {
            String(bytes, charset("GBK"))
        } catch (e: Exception) {
            utf8
        }
    }

    private fun displayNameOf(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun startsWith(bytes: ByteArray, magic: ByteArray): Boolean {
        if (bytes.size < magic.size) return false
        for (i in magic.indices) {
            if (bytes[i] != magic[i]) return false
        }
        return true
    }
}
