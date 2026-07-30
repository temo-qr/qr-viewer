-- ============================================================
-- إعداد قاعدة بيانات qr-viewer على Supabase
-- شغّل السكريبت ده مرة واحدة من: Supabase Dashboard -> SQL Editor -> New query
-- ============================================================

create table if not exists public.qr_files (
  id text primary key,                 -- 8 حروف عشوائية، ده اللي بيتكتب في رابط الباركود (view.html?id=...)
  storage_path text not null,          -- المسار داخل bucket "qr-files"، ثابت طول عمر السجل
  original_name text not null,         -- اسم الملف الأصلي (للعرض وتحديد امتداد الصورة/PDF)
  content_type text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  starts_at timestamptz not null default now(),                          -- تاريخ بدء صلاحية الباركود
  expires_at timestamptz not null default (now() + interval '1 year')    -- تاريخ الانتهاء، يتجدد لسنة من وقت الضغط على "تجديد"
);

alter table public.qr_files enable row level security;

-- أي حد (حتى غير مسجل دخول) يقدر يقرأ السجلات — عشان view.html يشتغل بدون تسجيل دخول
create policy "qr_files_public_select"
  on public.qr_files for select
  to anon, authenticated
  using (true);

-- الإضافة مسموحة فقط للمستخدم المسجل دخول (admin)
create policy "qr_files_authenticated_insert"
  on public.qr_files for insert
  to authenticated
  with check (true);

-- التحديث (الاستبدال) مسموح فقط للمستخدم المسجل دخول
create policy "qr_files_authenticated_update"
  on public.qr_files for update
  to authenticated
  using (true)
  with check (true);

-- ملاحظة مهمة: مفيش أي policy لـ delete هنا عن قصد.
-- يعني حتى لو حد يحاول يحذف سجل عبر الـ API مباشرة، Supabase هيرفض العملية.
-- ده تنفيذ فعلي على مستوى قاعدة البيانات لقرار "منع الحذف النهائي، استبدال فقط".

-- ============================================================
-- الحذف التلقائي بعد انتهاء الصلاحية بـ 30 يوم بدون تجديد
-- ============================================================
-- القاعدة: كل باركود صلاحيته سنة من تاريخ الرفع (starts_at/expires_at).
-- لو محدش جدده، بيفضل شغال كـ "منتهي" في لوحة التحكم لمدة 30 يوم إضافية (فترة سماح)
-- عشان الأدمن ياخد قراره، وبعدها بيتشال أوتوماتيك (السجل + الملف نفسه من الـ storage).
-- الحذف هنا مش بيتم عبر الـ anon/authenticated policies (اللي أصلاً مفيهاش delete) —
-- بيتم عبر Job مجدول شغال بصلاحيات أعلى (postgres)، فمبدأ "مفيش زرار حذف يدوي" فضل زي ما هو.

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- لازم تخزن الـ service_role key (من Project Settings -> API) كإعداد على مستوى الداتابيز
-- عشان الفانكشن تقدر تنادي على Storage API وتمسح الملف الفعلي. شغّل السطر ده مرة واحدة
-- (غيّر القيمتين بالقيم بتاعتك):
--
--   alter database postgres set app.settings.supabase_url = 'https://YOUR-PROJECT-REF.supabase.co';
--   alter database postgres set app.settings.service_role_key = 'YOUR-SERVICE-ROLE-KEY';
--
-- ملاحظة: الـ service_role key ده سري وقوي جدًا (بيتخطى كل RLS) — متحطوش في أي كود عميل
-- (زي supabase-config.js)، هو بيتخزن هنا فقط كإعداد داخلي في الداتابيز.

create or replace function public.cleanup_expired_qr_files()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  supabase_url text := current_setting('app.settings.supabase_url', true);
  service_key text := current_setting('app.settings.service_role_key', true);
begin
  for rec in
    select id, storage_path
    from public.qr_files
    where expires_at < now() - interval '30 days'
  loop
    if supabase_url is not null and service_key is not null then
      perform net.http_delete(
        url := supabase_url || '/storage/v1/object/qr-files/' || rec.storage_path,
        headers := jsonb_build_object('Authorization', 'Bearer ' || service_key)
      );
    end if;

    delete from public.qr_files where id = rec.id;
  end loop;
end;
$$;

select cron.schedule(
  'cleanup-expired-qr-files',
  '0 3 * * *', -- كل يوم الساعة 3 صباحًا
  $$select public.cleanup_expired_qr_files();$$
);

-- ============================================================
-- خطوات إضافية لازم تعملها يدويًا من لوحة تحكم Supabase (مش بالـ SQL):
-- ============================================================
--
-- 1) إنشاء الـ Storage bucket:
--    Storage -> New bucket -> الاسم: qr-files -> فعّل "Public bucket"
--
-- 2) إضافة Storage policies على bucket "qr-files" (من تبويب Policies بتاع الـ bucket):
--    - Policy للقراءة (SELECT): للجميع (public) - عشان الصور تتعرض في view.html
--    - Policy للرفع (INSERT) والتحديث (UPDATE): للـ authenticated role بس
--    - من غير أي policy لـ DELETE (نفس مبدأ الجدول بالظبط)
--
-- 3) إنشاء مستخدم الأدمن:
--    Authentication -> Users -> Add user -> حط الإيميل والباسورد بتاعتك
--    (ده اللي هتسجل بيه دخول في admin.html، بدل الباسورد اللي كان مكتوب في الكود قبل كده)
--
-- 4) خد من Project Settings -> API: الـ Project URL والـ anon public key
--    وحطهم في ملف supabase-config.js
--
-- 5) فعّل الحذف التلقائي: شغّل سطرين الـ "alter database" اللي فوق في SQL Editor
--    بعد ما تحط فيهم الـ URL والـ service_role key بتاعتك.
