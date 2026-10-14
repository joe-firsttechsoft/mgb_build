from datetime import datetime
import os
import re

def read_release_note_file(filename):
    """
    讀取指定檔案並將內容存入 txtFile 變數中。
    預設檔案名稱為 ReleaseNoteUpdateData.txt。
    """
    try:
        with open(filename, 'r', encoding='utf-8') as file:
            txtFile = file.read()
        return txtFile
    except FileNotFoundError:
        print(f"找不到檔案：{filename}")
        return ""
    except Exception as e:
        print(f"讀取檔案時發生錯誤：{e}")
        return ""

def parse_raw_input(input_str):
    """
    將多筆以雙引號包住的 ReleaseNote 資料解析成 list。
    每筆資料格式為：多行檔案名稱 + {release note}
    回傳格式：[[檔案1, 檔案2, ..., release note], ...]
    """
    # 基本格式檢查
    quote_count = input_str.count('"')
    if quote_count == 0:
        print("❌ 格式錯誤：找不到任何雙引號")
        return []
    if quote_count % 2 != 0:
        print(f"❌ 格式錯誤：雙引號數量為奇數（共 {quote_count} 個），請檢查 txt 內容")
        return []

    # 前置處理：移除 {} 內的 "（避免 regex 把區塊切斷）
    cleaned = []
    brace_depth = 0
    for c in input_str:
        if c == '{':
            brace_depth += 1
            cleaned.append(c)
        elif c == '}':
            if brace_depth > 0:
                brace_depth -= 1
            cleaned.append(c)
        elif c == '"' and brace_depth > 0:
            pass  # {} 內的 " 直接略過
        else:
            cleaned.append(c)
    input_str = ''.join(cleaned)

    # 找出所有雙引號包住的區塊
    blocks = re.findall(r'"(.*?)"', input_str, re.DOTALL)
    result = []

    for block in blocks:
        # 分離大括號內容
        if '{' in block and '}' in block:
            before_brace, brace_content = block.split('{', 1)
            noteContent = brace_content.rstrip('}').strip()
        else:
            before_brace = block
            noteContent = ""

        # 分割檔案名稱
        fileList = [line.strip() for line in before_brace.strip().split('\n') if line.strip()]
        fileList.append(noteContent)  # 把 release note 加在最後一個元素
        result.append(fileList)
    return result


def extract_files_and_content(rawData):
    """
    將 rawData 最後一筆視為 Release note 內容，其餘為檔案名稱。
    回傳 fileList 和 newContent。
    """
    if not rawData:
        return [], ""

    *fileList, newContent = rawData
    return fileList, newContent
    
def getDate():
    """
    回傳今天的日期，格式為 yyyymmdd（例如：20251105）
    """
    return datetime.today().strftime('%Y%m%d')

def extract_release_info(fileList, base_path):
    """
    從每個 Release note 檔案中提取：
    - 第二行的發行日期與版號
    - 向下搜尋到的前一次發行日期與版號（連續兩行）
    若找不到則填入 null。
    """
    LastReleaseDate = []
    LastReleaseVer = []
    Last2ReleaseDate = []
    Last2ReleaseVer = []

    date_pattern = re.compile(r'^\d{8}$')  # yyyymmdd 格式

    for filename in fileList:
        full_path = os.path.join(base_path, f"{filename}.txt")
        try:
            with open(full_path, 'r', encoding='utf-8') as f:
                lines = [line.strip() for line in f.readlines() if line.strip()]
        except FileNotFoundError:
            print(f"❌ 找不到檔案：{full_path}")
            LastReleaseDate.append("null")
            LastReleaseVer.append("null")
            Last2ReleaseDate.append("null")
            Last2ReleaseVer.append("null")
            continue

        # 取得第二行與第三行
        if len(lines) >= 3:
            LastReleaseDate.append(lines[1])
            LastReleaseVer.append(lines[2])
        else:
            LastReleaseDate.append("null")
            LastReleaseVer.append("null")

        # 向下搜尋前一次發行紀錄
        found = False
        for i in range(3, len(lines) - 1):
            if date_pattern.match(lines[i]):
                Last2ReleaseDate.append(lines[i])
                Last2ReleaseVer.append(lines[i + 1])
                found = True
                break

        if not found:
            Last2ReleaseDate.append("null")
            Last2ReleaseVer.append("null")

    return LastReleaseDate, LastReleaseVer, Last2ReleaseDate, Last2ReleaseVer

def get_max_item_number(text):
    """
    從文字中找出最大的序號項次。
    行首 數字. 一律視為序號（有無空格皆可）。
    """
    max_num = 0
    for line in text.split('\n'):
        m = re.match(r'^(\d+)\.', line)
        if m:
            num = int(m.group(1))
            if num > max_num:
                max_num = num
    return max_num

def renumber_items(content, start=1):
    """
    將內容重新編號並對齊，項次從 start 開始。
    - 行首 數字. 一律視為序號（有無空格皆可），依序重新編號，輸出統一補一個空格。
    - 沒帶序號的行是上一個項次的延續行：先扣掉原本序號標記寬度的縮排，
      再縮排對齊到新序號之後（例如 "3. " 就補 3 個空格、"10. " 補 4 個）。
    - 整個欄位都沒有序號時，整個欄位算一個項次（第一行補序號，其餘行對齊），
      不會每一行各自變成一個項次。
    - 空行保持空行。
    """
    marker = re.compile(r'^(\d+)\.\s*')
    counter = start
    indent = ''
    strip_width = 0
    started = False
    result = []
    for line in content.split('\n'):
        m = marker.match(line)
        if m or (not started and line.strip()):
            label = f"{counter}. "
            result.append(label + (line[m.end():] if m else line))
            indent = ' ' * len(label)
            strip_width = m.end() if m else 0
            counter += 1
            started = True
        elif line.strip():
            leading = len(line) - len(line.lstrip(' '))
            result.append(indent + line[min(leading, strip_width):])
        else:
            result.append('')
    return '\n'.join(result)

def increment_last_version_number(version_str):
    """
    將版號字串中的最後一組數字加一並回傳新的版號。
    例如：[ver]0.1.1.0.44 → [ver]0.1.1.0.45
    """
    numbers = re.findall(r'\d+', version_str)
    if not numbers:
        return version_str  # 沒有數字就不處理

    last_number = numbers[-1]
    incremented = str(int(last_number) + 1)

    # 使用 rpartition 只替換最後一組數字
    prefix, _, suffix = version_str.rpartition(last_number)
    new_version = prefix + incremented + suffix
    return new_version

def update_release_notes(base_path, fileList, LastReleaseDate, LastReleaseVer, Last2ReleaseDate, Last2ReleaseVer, newContent):
    """
    根據發行資訊與新內容更新 Release note 檔案。
    """
    today = getDate()
    updated_files = {}

    for i, filename in enumerate(fileList):
        full_path = os.path.join(base_path, f"{filename}.txt")

        if not os.path.exists(full_path):
            print(f"❌ 檔案不存在，跳過：{full_path}")
            continue

        try:
            with open(full_path, 'r', encoding='utf-8') as f:
                lines = [line.rstrip('\n') for line in f.readlines()]
        except Exception as e:
            print(f"⚠️ 無法讀取檔案 {full_path}：{e}")
            continue

        release_date = None
        release_ver = None

        # 判斷 ReleaseDate 與 ReleaseVer
        if LastReleaseDate[i] == "null":
            release_date = today
            print(f"🆕 {filename} 尚未建立版號")
            release_ver = "[ver]" + input(f"請輸入 {filename} 之版號：").strip()
        elif LastReleaseDate[i] < today:
            release_date = today
            release_ver = increment_last_version_number(LastReleaseVer[i])
        elif LastReleaseDate[i] == today:
            release_date = None
            release_ver = None

        # 清理 newContent 結尾
        newContent = newContent.rstrip('\n')

        # 插入邏輯
        if release_date and release_ver:
            # 換日：插入在第一行後，項次從 1 開始
            numbered_content = renumber_items(newContent, start=1)
            updated_lines = []
            updated_lines.append(lines[0])
            updated_lines.append(release_date)
            updated_lines.append(release_ver)
            updated_lines.append(numbered_content)
            updated_lines.extend(lines[1:])
        else:
            # 同一天：找出今日已有的最大項次，接續編號後插入 Last2ReleaseDate 前
            today_lines = []
            for line in lines[3:]:
                if Last2ReleaseDate[i] != "null" and line.strip() == Last2ReleaseDate[i]:
                    break
                today_lines.append(line)
            last_num = get_max_item_number('\n'.join(today_lines))
            numbered_content = renumber_items(newContent, start=last_num + 1)

            updated_lines = []
            inserted = False
            for line in lines:
                if not inserted and line.strip() == Last2ReleaseDate[i]:
                    updated_lines.append(numbered_content)
                    updated_lines.append(Last2ReleaseDate[i])
                    inserted = True
                else:
                    updated_lines.append(line)


        try:
            with open(full_path, 'w', encoding='utf-8') as f:
                f.write('\n'.join(updated_lines))
            updated_files[filename] = (release_date or "null", release_ver or "null")
            print(f"✅ 已更新：{filename}")
        except Exception as e:
            print(f"❌ 寫入失敗：{filename}，錯誤：{e}")

    return updated_files

def main():
    # 從環境變數讀取（由 run.sh 傳入）
    filename = os.environ.get("RELEASE_NOTE_INPUT", "ReleaseNoteUpdateData.txt")
    base_path = os.environ.get("RELEASE_NOTE_PATH", "")
    
    if not base_path:
        print("❌ 錯誤：未設定 RELEASE_NOTE_PATH 環境變數")
        return

    # Step 1: 讀取檔案
    txtFile = read_release_note_file(filename)

    if not txtFile:
        print("無法處理空的輸入資料。")
        return

    # Step 2: 解析原始資料
    rawData = parse_raw_input(txtFile)
    print('原始使資料：')
    print(rawData)
    for row in rawData:       
        # Step 3: 提取檔案名稱與內容
        fileList, newContent = extract_files_and_content(row)

        # Step 4: 顯示結果
        print("📂 檔案列表：")
        for f in fileList:
            print("-", f)

        print("\n📝 Release note 內容：")
        print(newContent)
        if newContent.endswith('\n'):
            print("⚠️ newContent 結尾有多餘的換行")

        # Step 5: 取出檔案中的Release Date + Ver
        LastReleaseDate, LastReleaseVer, Last2ReleaseDate, Last2ReleaseVer = extract_release_info(fileList,base_path)
        print("📂 檔案列表：",fileList)
        print("📅 LastReleaseDate:", LastReleaseDate)
        print("🔢 LastReleaseVer:", LastReleaseVer)
        print("📅 Last2ReleaseDate:", Last2ReleaseDate)
        print("🔢 Last2ReleaseVer:", Last2ReleaseVer)
        
        # Step 6: 更新Release Note
        updated_files = update_release_notes(base_path, fileList, LastReleaseDate, LastReleaseVer, Last2ReleaseDate, Last2ReleaseVer, newContent)

        # Step 7: 輸出更新的檔案路徑（供 run.ps1 顯示）
        print("\n📋 已更新的 Release Note 檔案：")
        for fname in updated_files:
            full_path = os.path.join(base_path, f"{fname}.txt")
            print(f"  {full_path}")
    
# 執行 main
if __name__ == "__main__":
    main()
    
    
