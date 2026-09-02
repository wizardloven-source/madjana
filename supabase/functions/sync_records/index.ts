// Edge Function: sync_records
// -----------------------------------------------
// تستقبل دفعة من السجلات المعلقة من تطبيق الموبايل
// وترفعها إلى قاعدة البيانات عبر دالة sync_records_batch.
//
// المصادقة: JWT من Supabase (تلقائياً عبر Authorization header)
// -----------------------------------------------

import { createClient } from "jsr:@supabase/supabase-js@2";

// الخادم العام للتحقق من JWT فقط (لا يُستخدم لتنفيذ RPC)
const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// العقد الموحد بين العميل والـ Edge Function والـ SQL
type SyncOperation = "insert" | "update" | "delete";

type SyncRecord = {
  table_name: string;
  operation: SyncOperation;
  operation_id?: string | null;
  record_id: string;
  payload: Record<string, unknown> | null;
  previous_version: number | null;
};

// قائمة المصادر المسموح بها (CORS) — تُضاف هنا الزبائن المعتمدة فقط
const ALLOWED_ORIGINS: string[] = [
  // التطبيقات الـ native لا ترسل Origin، لكن تُحتفظ بالقائمة لمن يستخدم Web لاحقاً
  // "https://app.madjana.example",
];

function getCorsHeaders(req: Request) {
  const origin = req.headers.get("Origin");
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}

// تحقق صريح (runtime) من صحة كل سجل قبل المتابعة
function validateRecord(r: Record<string, unknown>): { ok: true; value: SyncRecord } | { ok: false; error: string } {
  const ERR = (msg: string) => ({ ok: false as const, error: msg });

  if (typeof r !== "object" || r === null) return ERR("سجل غير صالح");
  if (typeof r["table_name"] !== "string" || r["table_name"] === "") return ERR("table_name ناقص");
  const op = r["operation"];
  if (op !== "insert" && op !== "update" && op !== "delete") return ERR("operation غير صالح");
  if (typeof r["record_id"] !== "string" || r["record_id"] === "") return ERR("record_id ناقص");
  const payload = r["payload"] ?? {};
  if (payload !== null && (typeof payload !== "object" || Array.isArray(payload))) {
    return ERR("payload غير صالح");
  }
  const pv = r["previous_version"];
  if (pv !== null && pv !== undefined && typeof pv !== "number") return ERR("previous_version غير صالح");

  return {
    ok: true,
    value: {
      table_name: r["table_name"] as string,
      operation: op as SyncOperation,
      operation_id: (r["operation_id"] as string) ?? null,
      record_id: r["record_id"] as string,
      payload: payload as Record<string, unknown> | null,
      previous_version: (pv as number | null) ?? null,
    },
  };
}

Deno.serve(async (req) => {
  const corsHeaders = getCorsHeaders(req);

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: corsHeaders },
    );
  }

  try {
    // التحقق من JWT
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace("Bearer ", "");

    const {
      data: { user },
      error: authError,
    } = await supabaseAdmin.auth.getUser(token);

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: corsHeaders },
      );
    }

    // إنشاء client بمفتاح المستخدم (لضمان عمل auth.uid() داخل SQL)
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const body = await req.json();
    const rawRecords = body?.records ?? [];

    if (!Array.isArray(rawRecords) || rawRecords.length === 0) {
      return new Response(
        JSON.stringify({ error: "Invalid records" }),
        { status: 400, headers: corsHeaders },
      );
    }

    // P0/16: مصفوفة رموز الحالة الموحدة:
    //   200 — نجاح (حتى مع نجاح جزئي؛ التفاصيل لكل سجل داخل details:
    //        ok/conflict/error/skipped) — لأن عميل Flutter (functions.invoke)
    //        يقذف استثناءً على أي رد غير 2xx، فـ 207/409 سيكسر معالجة التعارض.
    //   400 — حمولة غير صالحة، 401 — توكن غير صالح/منتهي،
    //   403 — رفض صلاحيات (RLS/دور) من دالة SQL،
    //   405 — طريقة خاطئة، 500 — خطأ خادم غير متوقع.
    const RPC_AUTHZ_MARKERS = [
      "غير مصرح",
      "ممنوع",
      "الحذف للمدير",
      "لا يمكن تحديد المزرعة",
      "الدور الحالي غير معروف",
      "لا ينتمي",
      "ليست من مزرعتك",
    ];

    // إزالة السجلات غير الصالحة مع توليد استجابة مفصلة لكل سجل مرفوض
    const normalized: SyncRecord[] = [];
    const rejected: { record_id: string; message: string }[] = [];
    for (const raw of rawRecords) {
      const check = validateRecord(raw as Record<string, unknown>);
      if (check.ok) {
        normalized.push(check.value);
      } else {
        rejected.push({
          record_id: (raw as Record<string, unknown>)?.["record_id"] as string ?? "",
          message: check.error,
        });
      }
    }

    if (normalized.length === 0) {
      return new Response(
        JSON.stringify({ error: "No valid records", rejected }),
        { status: 400, headers: corsHeaders },
      );
    }

    // استخدام client المستخدم (而非 service role) لضمان عمل auth.uid()
    // التحويل إلى عقد SQL: الحقل `data` وليس `payload`
    const rpcInput = normalized.map((r) => ({
      table_name: r.table_name,
      operation: r.operation,
      operation_id: r.operation_id,
      record_id: r.record_id,
      data: r.payload ?? {},
      previous_version: r.previous_version,
    }));

    const { data, error } = await supabaseUser.rpc("sync_records_batch", {
      p_records: JSON.stringify(rpcInput),
    });

    if (error) {
      console.error('Sync error:', error);
      // P0/16: تمييز رفض الصلاحيات (403) عن أخطاء الخادم العامة (500)
      const isAuthzDenied = RPC_AUTHZ_MARKERS.some((m) =>
        (error.message ?? "").includes(m)
      );
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: isAuthzDenied ? 403 : 500, headers: corsHeaders },
      );
    }

    // FIX #2: التحقق من صيغة الاستجابة المتوقعة
    if (!data || typeof data !== 'object') {
      throw new Error('Invalid response from sync function');
    }

    const typedData = data as {
      affected?: number;
      skipped?: number;
      errors?: number;
      details?: Array<{
        record_id: string;
        status: 'ok' | 'conflict' | 'error' | 'skipped';
        new_version?: number;
        server_version?: number;
        client_version?: number;
        message?: string;
      }>;
    };

    // تحويل الصيغة الجديدة إلى الصيغة القديمة للتوافق
    const details = typedData.details || [];
    const successIds = details
      .filter(d => d.status === 'ok')
      .map(d => d.record_id);
    const failedIds = details
      .filter(d => d.status === 'error')
      .map(d => d.record_id);
    const conflictIds = details
      .filter(d => d.status === 'conflict')
      .map(d => d.record_id);

    return new Response(
      JSON.stringify({
        success: true,
        affected: typedData.affected ?? 0,
        skipped: typedData.skipped ?? 0,
        errors: typedData.errors ?? 0,
        success_ids: successIds,
        failed_ids: failedIds,
        conflict_ids: conflictIds,
        details: details,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ error: (e as Error).message ?? "Internal error" }),
      { status: 500, headers: corsHeaders },
    );
  }
});