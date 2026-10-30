import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/blousab_message.dart';

/// تخزين الرسائل في SQLite بدل نص JSON واحد لكل محادثة في SharedPreferences.
/// الإدراج يكلّف O(1) بدل إعادة كتابة المحادثة كلها، والبحث بالفهرس.
/// تُرحَّل الرسائل القديمة (wasl_messages_*) تلقائيًا عند أول فتح.
class MessageStore {
  static const String _legacyPrefix = 'wasl_messages_';
  static const String _migratedFlag = 'blousab_messages_migrated_v1';

  static Future<Database>? _dbFuture;

  Future<Database> _database() => _dbFuture ??= _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'blousab_messages.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            sender_name TEXT NOT NULL,
            text TEXT NOT NULL,
            sent_at INTEGER NOT NULL,
            is_mine INTEGER NOT NULL DEFAULT 0,
            is_delivered INTEGER NOT NULL DEFAULT 0,
            attachment_path TEXT,
            attachment_name TEXT,
            PRIMARY KEY (id, conversation_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_conv_time ON messages (conversation_id, sent_at)',
        );
      },
    );
    await _migrateLegacy(db);
    return db;
  }

  Map<String, Object?> _toRow(BlousabMessage m) => <String, Object?>{
        'id': m.id,
        'conversation_id': m.conversationId,
        'sender_id': m.senderId,
        'sender_name': m.senderName,
        'text': m.text,
        'sent_at': m.sentAt.millisecondsSinceEpoch,
        'is_mine': m.isMine ? 1 : 0,
        'is_delivered': m.isDelivered ? 1 : 0,
        'attachment_path': m.attachmentPath,
        'attachment_name': m.attachmentName,
      };

  BlousabMessage _fromRow(Map<String, Object?> row) => BlousabMessage(
        id: row['id'] as String,
        conversationId: row['conversation_id'] as String,
        senderId: row['sender_id'] as String,
        senderName: row['sender_name'] as String,
        text: row['text'] as String,
        sentAt: DateTime.fromMillisecondsSinceEpoch(row['sent_at'] as int),
        isMine: (row['is_mine'] as int) == 1,
        isDelivered: (row['is_delivered'] as int) == 1,
        attachmentPath: row['attachment_path'] as String?,
        attachmentName: row['attachment_name'] as String?,
      );

  Future<void> _migrateLegacy(Database db) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migratedFlag) == true) return;
    final keys = prefs.getKeys().where((k) => k.startsWith(_legacyPrefix)).toList();
    final migratedKeys = <String>[];
    final batch = db.batch();
    for (final key in keys) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) {
        migratedKeys.add(key);
        continue;
      }
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded) {
          final message = BlousabMessage.fromJson(Map<String, dynamic>.from(item as Map));
          batch.insert('messages', _toRow(message), conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        migratedKeys.add(key);
      } catch (_) {
        // نترك المفتاح القديم كما هو إذا كان تالفًا بدل فقدان بياناته.
      }
    }
    await batch.commit(noResult: true);
    for (final key in migratedKeys) {
      await prefs.remove(key);
    }
    await prefs.setBool(_migratedFlag, true);
  }

  Future<List<BlousabMessage>> getMessages(String conversationId) async {
    final db = await _database();
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      orderBy: 'sent_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// يحفظ الرسالة، ويتجاهل المكررة (نفس المعرّف في نفس المحادثة).
  Future<void> saveMessage(BlousabMessage message) async {
    final db = await _database();
    await db.insert(
      'messages',
      _toRow(message),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// يعلّم رسالة أرسلتُها بأنها وصلت إلى الطرف الآخر (بعد ACK موقّع منه).
  /// يعيد true إذا تغيّرت رسالة فعلًا.
  Future<bool> markDelivered(String messageId, String conversationId) async {
    final db = await _database();
    final changed = await db.update(
      'messages',
      <String, Object?>{'is_delivered': 1},
      where: 'id = ? AND conversation_id = ? AND is_mine = 1 AND is_delivered = 0',
      whereArgs: <Object?>[messageId, conversationId],
    );
    return changed > 0;
  }

  Future<void> clearMessages(String conversationId) async {
    final db = await _database();
    await db.delete(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
    );
  }
}
