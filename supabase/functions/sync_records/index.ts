// Edge Function: sync_records
// -----------------------------------------------
// تستقبل دفعة من السجلات المعلقة من تطبيق الموبايل
// وترفعها إلى قاعدة البيانات عبر دالة sync_records_batch.
//
// المصادقة: JWT من Supabase (تلقائياً عبر Authorization header)
// -----------------------------------------------

import { createClient } from "jsr:@supabase/supabase-js@2";

// استخدام SERVICE_ROLE_KEY للكتابة الآمنة (لا يمر عبر RLS)
const supabase = createClient(
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
    } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: corsHeaders },
      );
    }

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
      payload: r.payload,
    }));

    // FIX #3: عدم إرسال user_id مطلقاً - الدالة ستستخدم auth.uid() فقط
    const { data, error } = await supabase.rpc("sync_records_batch", {
      p_records: JSON.stringify(normalized),
      // لا نرسل p_user_id أبداً
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
      success_ids?: string[];
      failed_ids?: string[];
      conflict_ids?: string[];
    };

    return new Response(
      JSON.stringify({
        success: true,
        success_ids: typedData.success_ids || [],
        failed_ids: typedData.failed_ids || [],
        conflict_ids: typedData.conflict_ids || [],
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