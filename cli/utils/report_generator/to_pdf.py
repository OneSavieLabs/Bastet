from markdown_pdf import MarkdownPdf, Section

def to_pdf(md_path: str, pdf_path: str):
    with open(md_path, "r", encoding="utf-8") as f:
        content = f.read()
        
    try:
        pdf = MarkdownPdf(toc_level=2, optimize=True)
        
        # Add content
        pdf.add_section(Section(content))

        # Save PDF
        pdf.save(pdf_path)
        
    except FileNotFoundError:
        print(f"❌ Error: Could not find file '{md_path}'")
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        