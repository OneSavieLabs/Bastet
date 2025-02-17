import os
import glob
import requests
import psycopg2
import json
from dotenv import load_dotenv

load_dotenv()

# database configuration
DB_CONFIG = {
    'host': os.getenv('POSTGRES_HOST', 'localhost'),
    'user': os.getenv('POSTGRES_USER'),
    'password': os.getenv('POSTGRES_PASSWORD'),
    'port': os.getenv('POSTGRES_PORT', '5432')
}

N8N_WEBHOOK_URL = os.getenv('N8N_WEBHOOK_URL')

def create_database():
    """create database if not exist"""

    try:
      conn = psycopg2.connect(**{**DB_CONFIG, 'database': 'postgres'})
      conn.autocommit = True
      cur = conn.cursor()
      
      cur.execute("SELECT 1 FROM pg_database WHERE datname = 'bastet'")
      if not cur.fetchone():
          cur.execute('CREATE DATABASE bastet')
      
      cur.close()
      conn.close()
    except Exception as e:
        print(f"Unexpected error in create_database: {str(e)}")
        raise e

def create_table():
    """create table if not exist"""
    try:
      conn = psycopg2.connect(**{**DB_CONFIG, 'database': 'bastet'})
      cur = conn.cursor()
      
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
      conn.commit()
      cur.close()
      conn.close()
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
            headers={'Content-Type': 'application/json', 'X-API-Key': '1234567890'}
        )

        if response.status_code != 200:
            error_details = response.json()
            raise Exception(f"Failed to scan contract: {error_details.get('message')}")

        return response.json()
    except Exception as e:
        print(f"Unexpected error in scan_contract: {str(e)}")
        raise e
    

def insert_analysis_result(file_path, result):
    """insert the analysis result into the database"""
    try:
        conn = psycopg2.connect(**{**DB_CONFIG, 'database': 'bastet'})
        cur = conn.cursor()

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
        
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        print(f"Unexpected error in insert_analysis_result: {str(e)}")
        raise e

def main(folder_path):
    print('Scanning contracts...')
    """main function"""
    # make sure the database and table exist
    try:
        create_database()
        create_table()
    except Exception as e:
        print(f"Unexpected error in main: {str(e)}")
        raise e

    print('Database and table created.')
    
    # get all .sol files
    contract_files = glob.glob(os.path.join(folder_path, '**/*.sol'), recursive=True)
    total_files = len(contract_files)

    print(f'Found {total_files} contract files.')

    success_count = 0
    error_count = 0

    for file_path in contract_files:
        try:
            print(f"Processing: {file_path}")
            
            relative_path = os.path.relpath(file_path, folder_path)
            
            # scan the contract
            result = scan_contract(file_path)
            
            # store the result
            insert_analysis_result(relative_path, result)
            success_count += 1
            
            print(f"Successfully processed: {relative_path}")
            
        except Exception as e:
            error_count += 1
            print(f"Error processing {file_path}: {str(e)}")

    print('-' * 100)
    print("\nProcessing Summary:")
    print(f"Total files: {total_files}")
    print(f"Successfully processed: {success_count}")
    print(f"Errors: {error_count}")

if __name__ == "__main__":
    import sys
    
    if len(sys.argv) != 2:
        print("Usage: python script.py <folder_path>")
        sys.exit(1)
    
    folder_path = sys.argv[1]
    main(folder_path)