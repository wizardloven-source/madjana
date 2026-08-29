# 📤 نشر Edge Function للمزامنة

## الطريقة 1: النشر اليدوي (الأسهل)

### الخطوة 1: تسجيل الدخول إلى Supabase
```bash
supabase login
```
- سيفتح متصفح لتسجيل الدخول
- بعد النجاح، سيتم حفظ Access Token

### الخطوة 2: ربط المشروع
```bash
supabase link --project-ref iefwbcwhpyajhohpxwmj
```
- `iefwbcwhpyajhohpxwmj` هو Project Ref من URL في الكود

### الخطوة 3: التأكد من وجود config.toml
```bash
cat > supabase/config.toml << 'TOML'
[api]
enabled = true
port = 54321
schemas = ["public", "storage", "graphql_public"]
extra_search_path = ["public", "extensions"]
max_rows = 1000

[db]
port = 54322
shadow_port = 54320
major_version = 15

[studio]
enabled = true
port = 54323
api_url = "http://localhost"

[auth]
enabled = true
site_url = "http://localhost:3000"
additional_redirect_urls = ["https://localhost:3000"]
jwt_expiry = 3600
enable_signup = true
enable_anonymous_sign_ins = false
enable_email_confirmations = false

[functions.sync_records]
verify_jwt = true
TOML
```

### الخطوة 4: نشر Edge Function
```bash
cd /workspace
supabase functions deploy sync_records
```

### الخطوة 5: التحقق من النشر
```bash
supabase functions list
```

---

## الطريقة 2: النشر عبر Dashboard (بديل)

إذا واجهت مشاكل مع CLI:

1. اذهب إلى https://supabase.com/dashboard/project/iefwbcwhpyajhohpxwmj
2. انتقل إلى **Edge Functions**
3. اضغط **Deploy new function**
4. اختر **Deploy from GitHub** أو **Copy/Paste**
5. الصق محتوى `/workspace/supabase/functions/sync_records/index.ts`
6. اسم الدالة: `sync_records`
7. اضغط **Deploy**

---

## الطريقة 3: استخدام CURL مباشرة

بعد النشر، اختبر الدالة:

```bash
curl -X POST 'https://iefwbcwhpyajhohpxwmj.supabase.co/functions/v1/sync_records' \
  -H 'Authorization: Bearer YOUR_JWT_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{
    "records": [
      {
        "table": "egg_production",
        "action": "INSERT",
        "data": {
          "id": "test-123",
          "farm_id": "farm-123",
          "flock_id": "flock-123",
          "date": "2025-01-15",
          "total_eggs": 100,
          "salable_eggs": 95,
          "created_at": "2025-01-15T10:00:00Z"
        }
      }
    ],
    "user_id": "user-123"
  }'
```

---

## ⚠️ ملاحظات مهمة

### 1. صلاحيات الدالة
الدالة تستخدم `SUPABASE_SERVICE_ROLE_KEY` مما يتجاوز RLS، لذا:
- يجب أن تكون المصادقة JWT صحيحة
- يجب التحقق من `user_id` داخل الدالة

### 2. دالة sync_records_batch في PostgreSQL
تأكد من وجود دالة SQL باسم `sync_records_batch`:

```sql
-- في Supabase Dashboard > SQL Editor
CREATE OR REPLACE FUNCTION sync_records_batch(
  p_records JSONB,
  p_user_id UUID DEFAULT auth.uid()
) RETURNS JSONB AS $$
DECLARE
  rec JSONB;
  result JSONB := jsonb_build_object('uploaded', 0, 'errors', '[]');
BEGIN
  FOR rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    -- معالجة كل سجل حسب نوعه
    -- ... منطق الرفع
  END LOOP;
  
  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 3. اختبار محلي
```bash
supabase start
supabase functions serve sync_records --env-file .env
```

---

## 🔍 استكشاف الأخطاء

### خطأ: "Function not found"
```bash
supabase functions deploy sync_records --project-ref iefwbcwhpyajhohpxwmj
```

### خطأ: "Unauthorized"
- تأكد من JWT Token صحيح
- تحقق من `verify_jwt = true` في config

### خطأ: "Database function not found"
- أنشئ دالة `sync_records_batch` في SQL Editor
