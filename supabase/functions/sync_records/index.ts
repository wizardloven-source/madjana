// Edge Function: sync_records
// -----------------------------------------------
// تستقبل دفعة من السجلات المعلقة من تطبيق الموبايل
// وترفعها إلى قاعدة البيانات عبر دالة sync_records_batch.
//
// المصادقة: JWT من Supabase (تلقائياً عبر Authorization header)
// -----------------------------------------------

import { createClient } from "jsr:@supabase/supabase-js@2";

// الخادم العام للقراءة (GET، CORS)
const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };

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
    const { records } = body as {
      records: Array<{ 
        table_name: string; 
        operation: string; 
        record_id: string; 
        payload: Record<string, unknown> 
      }>;
    };

    if (!Array.isArray(records) || records.length === 0) {
      return new Response(
        JSON.stringify({ error: "Invalid records" }),
        { status: 400, headers: corsHeaders },
      );
    }

    // FIX #1 & #2: إرسال العقد الصحيح مباشرة دون تحويل
    // SQL يتوقع الآن: table_name, operation, record_id, payload
    const normalized = records.map((r) => ({
      table_name: r.table_name,
      operation: r.operation,
      record_id: r.record_id,
      data: r.payload ?? {},
      previous_version: r.previous_version ?? null,
    }));

    // استخدام client المستخدم (而非 service role) لضمان عمل auth.uid()
    const { data, error } = await supabaseUser.rpc("sync_records_batch", {
      p_records: JSON.stringify(normalized),
    });

    if (error) {
      console.error('Sync error:', error);
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: 500, headers: corsHeaders },
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