import os
import sys
from pathlib import Path
from datetime import datetime
import json
import traceback

# ============================================================
# الإعدادات المحدثة - جمع جميع الملفات البرمجية
# ============================================================

# مجلدات يتم تخطيها
IGNORE_DIRS = {
    '__pycache__', 'venv', '.venv', 'env', '.git', 'backups', 'logs', 
    'migrations', 'node_modules', 'dist', 'build', '.idea', 
    '.vscode', 'temp', 'temp_backup', '.mypy_cache', 
    '.pytest_cache', 'htmlcov',
    '.dart_tool',      # ← تجاهل مجلدات أدوات Flutter
    'windows',         # ← مجلدات المنصات (غير ضرورية للكود)
    'linux',
    'macos',
    'web'
}

# امتدادات الملفات غير النصية التي يجب تجاهلها
IGNORE_FILES = {
    '.pyc', '.db', '.sqlite', '.log', '.bak', '.pyo', '.pyd', 
    '.so', '.dll', '.exe', '.zip', '.rar', '.7z', '.tar', 
    '.gz', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', 
    '.mp3', '.mp4', '.wav', '.pdf', '.doc', '.docx', 
    '.xls', '.xlsx', 
    '.g.dart',         # ← تجاهل الملفات المولدة تلقائياً
    '.freezed.dart'    # ← تجاهل ملفات Freezed المولدة
}

# الامتدادات المسموح بجمع محتواها النصي (محدثة)
EXTENSIONS = {
    '.py', '.txt', '.json', '.yaml', '.yml', '.ini', '.cfg', 
    '.md', '.rst', '.html', '.css', '.js',
    '.dart',           # ← ✅ ملفات Flutter الأساسية
    '.ts',             # ← ✅ TypeScript (Supabase Edge Functions)
    '.sql',            # ← ✅ مخطط قاعدة البيانات
    '.xml',            # ← ✅ ملفات Android
    '.gradle',         # ← ✅ Gradle build files
    '.properties',     # ← ✅ ملفات الخصائص
    '.kt',             # ← ✅ Kotlin (Android)
    '.java',           # ← ✅ Java (Android)
    '.cmake',          # ← ✅ CMake (Windows Desktop)
    '.cpp',            # ← ✅ C++ (Windows Desktop)
    '.h',              # ← ✅ Header files
    '.c',              # ← ✅ C files
    '.cc'              # ← ✅ C++ files
}

# ============================================================
# الدوال المصلحة
# ============================================================

def should_ignore_path(path):
    """
    التحقق مما إذا كان المسار يجب تجاهله.
    """
    path_obj = Path(path)
    
    # التحقق من المجلدات المستثناة
    for part in path_obj.parts:
        if part in IGNORE_DIRS:
            return True
    
    # التحقق من امتداد الملف
    if path_obj.suffix.lower() in IGNORE_FILES:
        return True
    
    # تجاهل الملفات المولدة
    if path_obj.name.endswith('.g.dart') or path_obj.name.endswith('.freezed.dart'):
        return True
        
    return False

def read_file_safely(file_path):
    """
    قراءة الملف بشكل آمن مع دعم الترميز العربي.
    """
    encodings = ['utf-8', 'utf-8-sig', 'cp1256', 'iso-8859-6', 'windows-1256']
    
    try:
        # حد 10 ميجابايت للملف الواحد (زيادة قليلة)
        if os.path.getsize(file_path) > 10 * 1024 * 1024:
            return "⚠️ ملف كبير جداً (أكبر من 10 ميجابايت)، تم تخطي المحتوى.", 'skipped'
            
        for encoding in encodings:
            try:
                with open(file_path, 'r', encoding=encoding) as f:
                    return f.read(), encoding
            except (UnicodeDecodeError, UnicodeError):
                continue
    except PermissionError:
        return "⚠️ خطأ: لا توجد صلاحية للوصول (Permission Denied).", 'permission_denied'
    except Exception as e:
        return f"⚠️ خطأ غير متوقع: {str(e)}", 'error'
    
    return "⚠️ تعذر القراءة: ترميز غير معروف.", 'unknown'

def create_summary(all_files, start_path):
    """
    إنشاء ملخص إحصائي شامل للملفات.
    """
    summary = [
        "=" * 80,
        "📊 ملخص المشروع (YAseen ERP) - النسخة الكاملة",
        "=" * 80,
        f"📁 مسار المشروع: {start_path}",
        f"📅 تاريخ الإنشاء: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"📄 إجمالي الملفات المكتشفة: {len(all_files)}",
        ""
    ]
    
    # إحصائيات حسب الامتداد
    ext_count = {}
    for rel_path, _ in all_files:
        ext = Path(rel_path).suffix or 'بدون امتداد'
        ext_count[ext] = ext_count.get(ext, 0) + 1
    
    summary.append("📊 توزيع الملفات حسب الامتداد:")
    for ext, count in sorted(ext_count.items(), key=lambda x: -x[1]):
        summary.append(f"   {ext}: {count} ملف")
    
    # إحصائيات المجلدات الرئيسية
    folders = {}
    for rel_path, _ in all_files:
        parts = Path(rel_path).parts
        if len(parts) >= 2:
            folder = f"{parts[0]}/{parts[1]}" if len(parts) >= 3 else parts[0]
        else:
            folder = "Root"
        folders[folder] = folders.get(folder, 0) + 1
    
    summary.append("\n📁 توزيع الملفات حسب المجلدات (أهم 10):")
    for folder, count in sorted(folders.items(), key=lambda x: -x[1])[:10]:
        summary.append(f"   📂 {folder}: {count} ملف")
    
    # إحصائيات حسب التطبيق/الحزمة
    packages = {}
    for rel_path, _ in all_files:
        parts = Path(rel_path).parts
        if len(parts) >= 2:
            if parts[0] == 'apps' and len(parts) >= 3:
                key = f"apps/{parts[1]}"
            elif parts[0] == 'packages' and len(parts) >= 3:
                key = f"packages/{parts[1]}"
            else:
                key = parts[0]
        else:
            key = "Root"
        packages[key] = packages.get(key, 0) + 1
    
    summary.append("\n📦 توزيع الملفات حسب التطبيقات والحزم:")
    for pkg, count in sorted(packages.items(), key=lambda x: -x[1]):
        summary.append(f"   📦 {pkg}: {count} ملف")
    
    summary.append("\n" + "=" * 80 + "\n")
    return "\n".join(summary)

def collect_code():
    """
    الدالة الأساسية لجمع الأكواد.
    """
    project_path = os.getcwd()
    print(f"\n🚀 بدء معالجة المشروع من: {project_path}")
    
    # جمع الملفات
    all_files = []
    for ext in EXTENSIONS:
        for file_path in Path(project_path).rglob(f"*{ext}"):
            if not should_ignore_path(file_path):
                rel_path = file_path.relative_to(project_path)
                all_files.append((str(rel_path), str(file_path)))

    all_files.sort()

    if not all_files:
        print("❌ لم يتم العثور على ملفات برمجية!")
        return

    # إنشاء ملف المخرجات
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_file = os.path.join(project_path, f"Project_Full_Code_{timestamp}.txt")
    
    try:
        with open(output_file, 'w', encoding='utf-8') as out:
            out.write(create_summary(all_files, project_path))
            
            success_count = 0
            for idx, (rel_path, full_path) in enumerate(all_files, 1):
                print(f"   [{idx}/{len(all_files)}] قراءة: {rel_path}")
                
                content, encoding = read_file_safely(full_path)
                
                out.write(f"\n{'='*80}\n")
                out.write(f"📄 PATH: {rel_path}\n")
                out.write(f"🔢 ENCODING: {encoding}\n")
                out.write(f"{'='*80}\n\n")
                out.write(content)
                out.write("\n\n")
                
                if encoding not in ['unknown', 'error', 'permission_denied', 'skipped']:
                    success_count += 1
            
        print(f"\n✅ نجحت العملية! تم حفظ كود {success_count} ملف في:\n👉 {output_file}")
    except Exception as e:
        print(f"❌ خطأ فادح أثناء كتابة ملف الإخراج: {e}")

def main():
    print("\n" + "╔" + "═"*48 + "╗")
    print("║" + " "*8 + "YAseen ERP - Full Code Collector v2" + "*"*8 + "║")
    print("╚" + "═"*48 + "╝")
    
    print("\n📋 هذا الإصدار يجمع:")
    print("   ✅ ملفات Flutter (.dart)")
    print("   ✅ ملفات TypeScript (.ts)")
    print("   ✅ ملفات SQL (.sql)")
    print("   ✅ ملفات التهيئة (.yaml, .json, .md)")
    print("   ✅ ملفات Android (.kt, .java, .gradle)")
    print("   ✅ ملفات Windows (.cpp, .h, .cmake)")
    print("   ❌ يتجاهل الملفات المولدة (.g.dart, .freezed.dart)")
    print("   ❌ يتجاهل مجلدات الأدوات (.dart_tool, build, ...)")
    
    print("\nخيارات العمل:")
    print("1. جمع كافة الأكواد (للفحص الشامل) ✅")
    print("2. خروج")
    
    choice = input("\nاختر (1-2): ").strip()
    
    if choice == "1":
        collect_code()
    else:
        print("👋 مع السلامة!")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n⚠️ تم إيقاف العملية بواسطة المستخدم.")