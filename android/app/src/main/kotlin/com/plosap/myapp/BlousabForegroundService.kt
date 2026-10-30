package com.plosap.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * خدمة تعمل في المقدمة (Foreground Service) تُبقي عملية بلوساب حيّة حين يُنقل
 * التطبيق إلى الخلفية، فلا يقتل أندرويد اتصالات البلوتوث والشبكة المحلية
 * ولا يتوقف ترحيل الرسائل. تظهر للمستخدم كإشعار دائم يمكنه إيقافه من الإعدادات.
 *
 * ملاحظة: إغلاق التطبيق بالسحب من قائمة التطبيقات الأخيرة يُنهي محرك Flutter
 * رغم هذه الخدمة؛ هدفها حماية التطبيق في الخلفية لا بعد الإغلاق الكامل.
 */
class BlousabForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "blousab_background"
        private const val NOTIFICATION_ID = 7101
        @Volatile var running: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, BlousabForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BlousabForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (e: Exception) {
            // مثلًا: صلاحية البلوتوث غير ممنوحة على أندرويد 14. لا نُسقط التطبيق.
            running = false
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "بلوساب في الخلفية",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "يُبقي اتصالات البلوتوث والشبكة المحلية نشطة"
            manager.createNotificationChannel(channel)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT
        val pending = PendingIntent.getActivity(this, 0, launch, flags)

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID)
        else Notification.Builder(this)

        return builder
            .setContentTitle("بلوساب يعمل في الخلفية")
            .setContentText("الاتصال بالأجهزة القريبة وترحيل الرسائل نشطان")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()
    }
}
