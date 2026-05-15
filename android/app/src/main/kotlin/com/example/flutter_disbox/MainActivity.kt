package com.example.flutter_disbox

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Set a default method call handler to prevent Missing type parameter errors
        // This is a workaround for flutter_local_notifications plugin issues on some devices
        try {
            intent?.extras?.let { bundle ->
                // Clear any problematic extras that might cause type parameter issues
                bundle.keySet().forEach { key ->
                    if (bundle.get(key) == null) {
                        bundle.remove(key)
                    }
                }
            }
        } catch (e: Exception) {
            // Ignore any errors during cleanup
            android.util.Log.w("MainActivity", "Error cleaning intent extras: ${e.message}")
        }
        
        super.onCreate(savedInstanceState)
    }
}
