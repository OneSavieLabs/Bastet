import json
from docxtpl import DocxTemplate
from docx2pdf import convert

def json_to_office(json_path: str, docx_template_path: str, output_docx: str, output_pdf: str):
    try:
        # Load JSON context
        with open(json_path, "r", encoding="utf-8") as file:
            context = json.load(file)

        # Render DOCX from template
        doc = DocxTemplate(docx_template_path)
        doc.render(context)
        doc.save(output_docx)
        print(f"DOCX successfully generated: {output_docx}")

        # Convert DOCX to PDF
        convert(output_docx, output_pdf)
        print(f"PDF successfully generated : {output_pdf}")
            

    except FileNotFoundError as e:
        print(f"[Error] File not found: {e.filename}")
    except json.JSONDecodeError as e:
        print(f"[Error] Invalid JSON format: {str(e)}")
    except Exception as e:
        print(f"[Error] Unexpected error: {str(e)}")

