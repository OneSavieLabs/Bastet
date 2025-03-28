import json
import os
import glob

def modify_openai_nodes(file_path):
    """
    讀取指定的 JSON 檔案，修改所有 type 為 '@n8n/n8n-nodes-langchain.openAi' 的節點，
    在其 parameters['options'] 中添加 'maxTokens': 16000
    
    Args:
        file_path: JSON 檔案的路徑
    
    Returns:
        bool: 是否有進行修改
    """
    try:
        # 讀取 JSON 檔案
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        modified = False
        
        # 檢查是否有 'nodes' 欄位
        if 'nodes' in data:
            # 遍歷所有節點
            for node in data['nodes']:
                # 檢查節點類型是否為目標類型
                if node.get('type') == '@n8n/n8n-nodes-langchain.openAi':
                    # 檢查是否有 parameters 欄位
                    if 'parameters' in node:
                        # 檢查是否有 options 欄位，若沒有則創建
                        if 'options' not in node['parameters']:
                            node['parameters']['options'] = {}
                        
                        # 添加 maxTokens 欄位
                        node['parameters']['options']['maxTokens'] = 16000
                        modified = True
                        print(f"修改了檔案 {file_path} 中的一個 openAi 節點")
        
        # 如果有修改，則寫回檔案
        if modified:
            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            return True
        
        return False
    
    except Exception as e:
        print(f"處理檔案 {file_path} 時發生錯誤: {e}")
        return False

def process_all_json_files(directory):
    """
    處理指定目錄下的所有 JSON 檔案
    
    Args:
        directory: 目錄路徑
    """
    # 取得所有 JSON 檔案
    json_files = glob.glob(os.path.join(directory, "*.json"))
    
    if not json_files:
        print(f"在 {directory} 目錄中找不到任何 JSON 檔案")
        return
    
    modified_count = 0
    
    # 處理每個檔案
    for file_path in json_files:
        if modify_openai_nodes(file_path):
            modified_count += 1
    
    print(f"共處理了 {len(json_files)} 個 JSON 檔案，修改了 {modified_count} 個檔案")

if __name__ == "__main__":
    # 指定要處理的目錄
    target_directory = "n8n_workflow"
    
    # 檢查目錄是否存在
    if not os.path.exists(target_directory):
        print(f"目錄 '{target_directory}' 不存在")
    else:
        print(f"開始處理目錄 '{target_directory}' 中的 JSON 檔案...")
        process_all_json_files(target_directory)