
package com.example.rental_monita

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName =
        "com.example.rental_monita/bluetooth_permissions"

    private var permissionResult: MethodChannel.Result? = null

    private val permissionRequestCode = 1001

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // FCM通知チャンネルを作成する
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "rental_monita_notifications",
                "レンタルモニ太のお知らせ",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "レンタルモニ太からの通知"
            }

            val notificationManager =
                getSystemService(NotificationManager::class.java)

            notificationManager.createNotificationChannel(channel)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // FlutterからBluetooth権限の確認・要求を受け付ける
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->

            if (call.method != "requestBluetoothPermissions") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            // Android 12未満では新しいBluetooth権限は不要
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                result.success(true)
                return@setMethodCallHandler
            }

            val permissions = arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT
            )

            // 必要な権限がすべて許可済みなら、そのまま続行する
            val allGranted = permissions.all {
                checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }

            if (allGranted) {
                result.success(true)
                return@setMethodCallHandler
            }

            // 権限要求が重複しないようにする
            if (permissionResult != null) {
                result.error(
                    "permission_in_progress",
                    "Bluetooth権限を確認中です",
                    null
                )
                return@setMethodCallHandler
            }

            permissionResult = result

            requestPermissions(
                permissions,
                permissionRequestCode
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults
        )

        if (requestCode != permissionRequestCode) return

        // 権限要求の結果をFlutter側へ返す
        val granted =
            grantResults.isNotEmpty() &&
            grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            }

        permissionResult?.success(granted)
        permissionResult = null
    }
}
