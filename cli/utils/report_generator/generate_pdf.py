from markdown_pdf import MarkdownPdf, Section

def generate_pdf(markdown_text: str, pdf_path: str):
    if not markdown_text.strip():
        print("⚠️ Markdown content is empty. Cannot generate PDF.")
        exit(1)
    
    pdf = MarkdownPdf(toc_level=2, optimize=True)

    # Add content
    pdf.add_section(Section(markdown_text))

    # Save PDF
    pdf.save(pdf_path)
    