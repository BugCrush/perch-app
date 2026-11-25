package dev.perch.perch_app

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity: local_auth (the app lock's fingerprint / face / PIN prompt) needs one.
//
// Pairing links opened from outside the app (a phone camera scanning the host's QR code:
// https://<relay>/pair#… or perch://pair?…) reach Flutter on the channel "perch/links":
// `initialLink` once for the link that started the app, then `link` for each new one.
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var initial: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initial = linkOf(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "perch/links").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initialLink") {
                    result.success(initial)
                    initial = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        linkOf(intent)?.let { channel?.invokeMethod("link", it) }
    }

    private fun linkOf(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_VIEW) intent.dataString else null
}
