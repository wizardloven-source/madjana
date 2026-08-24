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
    const { records, user_id } = body as {
      records: Array<{ table: string; action: string; data: Record<string, unknown> }>;
      user_id: string;
    };

    if (!Array.isArray(records) || records.length === 0) {
      return new Response(
        JSON.stringify({ error: "Invalid records" }),
        { status: 400, headers: corsHeaders },
      );
    }

    // تحويل السجلات إلى صيغة تستهلكها sync_records_batch
    const normalized = records.map((r) => ({
      table: r.table,
      action: r.action ?? "INSERT",
      data: r.data,
    }));

    const { data, error } = await supabase.rpc("sync_records_batch", {
      p_records: JSON.stringify(normalized),
      p_user_id: user_id ?? user.id,
    });

    if (error) {
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: 500, headers: corsHeaders },
      );
    }

    return new Response(JSON.stringify(data), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(
      JSON.stringify({ error: (e as Error).message ?? "Internal error" }),
      { status: 500, headers: corsHeaders },
    );
  }
});