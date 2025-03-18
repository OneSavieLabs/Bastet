import os
import glob
import requests
import psycopg
from psycopg.rows import dict_row
import json
from dotenv import load_dotenv
from tqdm import tqdm

load_dotenv()

N8N_WEBHOOK_URL = os.getenv('N8N_WEBHOOK_URL')

def get_conn(dbname='postgres'):
    """Get database connection with standard configuration"""
    return psycopg.connect(
        host=os.getenv('POSTGRES_HOST', 'localhost'),
        user=os.getenv('POSTGRES_USER'),
        password=os.getenv('POSTGRES_PASSWORD'),
        port=os.getenv('POSTGRES_PORT', '5432'),
        dbname=dbname,
        autocommit=True,
        row_factory=dict_row,
    )

def create_database():
    """create database if not exist"""
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 FROM pg_database WHERE datname = 'bastet'")
                if not cur.fetchone():
                    cur.execute('CREATE DATABASE bastet')
    except Exception as e:
        print(f"Unexpected error in create_database: {str(e)}")
        raise e

def create_table():
    """create table if not exist"""
    try:
        with get_conn('bastet') as conn:
            with conn.cursor() as cur:
                create_table_query = '''
                CREATE TABLE IF NOT EXISTS analysis (
                    id SERIAL PRIMARY KEY,
                    contract_name VARCHAR(1024),
                    contract_path TEXT,
                    audit_result JSONB,
                    audit_result_review BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                '''
                cur.execute(create_table_query)
    except Exception as e:
        print(f"Unexpected error in create_table: {str(e)}")
        raise e

def scan_contract(file_path):
    """scan the contract file and return the analysis result"""
    try:
        with open(file_path, 'r') as file:
            contract_content = file.read()
        
        # call n8n webhook
        response = requests.post(
            N8N_WEBHOOK_URL,
            json={'contract_content': contract_content},
            headers={'Content-Type': 'application/json', 'X-API-Key': '1234567890'},
        )

        if response.status_code != 200:
            error_details = response.json()
            raise Exception(f"Failed to scan contract: {error_details.get('message')}")

        return response.json()
    except Exception as e:
        print(f"Unexpected error in scan_contract: {str(e)}")
        raise e
    

def insert_analysis_result(cur, file_path, result):
    """insert the analysis result into the database"""
    try:
        file_name = os.path.basename(file_path)
        audit_result = json.dumps(result)

        insert_query = '''
        INSERT INTO analysis 
        (contract_name, contract_path, audit_result)
        VALUES (%s, %s, %s)
        '''

        cur.execute(insert_query, (
            file_name, 
            file_path, 
            audit_result,
        ))

    except Exception as e:
        print(f"Unexpected error in insert_analysis_result: {str(e)}")
        raise e

def main(folder_path):
    print('Scanning contracts...')
    # TODO: move create_database, create_table to migration script
    try:
        create_database()
        create_table()
    except Exception as e:
        print(f"Unexpected error in main: {str(e)}")
        raise e

    print('Database and table created.')
    
    contract_files = glob.glob(os.path.join(folder_path, '**/*.sol'), recursive=True)
    total_files = len(contract_files)
    print(f'Found {total_files} contract files.')

    success_count = 0
    error_count = 0

    with get_conn('n8n') as conn:
        with conn.cursor() as cur:
            for file_path in tqdm(contract_files, 
                                 desc="Processing contracts", 
                                 unit="file",
                                 ncols=100,
                                 colour='blue',
                                 bar_format='{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} files [Time: {elapsed}]'):
                try:
                    relative_path = os.path.relpath(file_path, folder_path)
                    result = scan_contract(file_path)

                    insert_analysis_result(cur, relative_path, result)
                    success_count += 1
                    
                    tqdm.write("\033[92m✅ Successfully processed: {}\033[0m".format(relative_path))
                    
                except Exception as e:
                    error_count += 1
                    tqdm.write("\033[91m❌ Error processing {}: {}\033[0m".format(file_path, str(e)))

    print('\n' + '=' * 50)
    print("📊 Processing Summary".center(50))
    print('=' * 50)
    print(f"📁 Total files processed: {total_files}")
    print(f"✅ Successfully processed: {success_count}")
    print(f"❌ Errors encountered: {error_count}")
    print('=' * 50 + '\n')

if __name__ == "__main__":
    import sys
    
    if len(sys.argv) != 2:
        print("Usage: python script.py <folder_path>")
        sys.exit(1)
    
    folder_path = sys.argv[1]
    main(folder_path)