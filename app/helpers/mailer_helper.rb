# Building blocks for HTML emails. Mail clients drop most <style> rules, so
# every style is inline, and layout uses tables so Outlook keeps it.
module MailerHelper
  FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif".freeze
  PRIMARY = "#066fd1".freeze
  TEXT = "font-family:#{FONT};font-size:15px;line-height:24px;color:#334155;".freeze
  SMALL = "font-family:#{FONT};font-size:13px;line-height:20px;color:#64748b;".freeze

  def email_heading(text)
    tag.h1(text, style: "margin:0 0 20px;font-family:#{FONT};font-size:22px;line-height:30px;font-weight:700;color:#0f172a;")
  end

  def email_paragraph(text = nil, &block)
    tag.p(block ? capture(&block) : text, style: "margin:0 0 16px;#{TEXT}")
  end

  # A link styled as a button; the colored cell keeps it a button where padding on <a> is ignored.
  def email_button(text, url)
    link = link_to(text, url, target: "_blank", rel: "noopener",
                   style: "display:inline-block;padding:12px 24px;font-family:#{FONT};font-size:15px;line-height:20px;" \
                          "font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;")
    email_table(style: "margin:8px 0 24px;") do
      tag.tr { tag.td(link, bgcolor: PRIMARY, style: "border-radius:8px;background-color:#{PRIMARY};") }
    end
  end

  def email_note(text, tone: :info)
    colors = tone == :warning ? "background-color:#fff7ed;color:#9a3412;" : "background-color:#f1f5f9;color:#475569;"
    email_table(width: "100%", style: "margin:0 0 20px;") do
      tag.tr do
        tag.td(text, style: "padding:12px 16px;border-radius:8px;font-family:#{FONT};font-size:13px;line-height:20px;#{colors}")
      end
    end
  end

  # Plain URL under the button for clients that block it.
  def email_link_fallback(url)
    safe_join([
      tag.div(raw("&nbsp;"), style: "margin:24px 0 16px;border-top:1px solid #e2e8f0;font-size:1px;line-height:1px;"),
      tag.p(t("mailer.link_fallback"), style: "margin:0 0 4px;#{SMALL}"),
      tag.p(link_to(url, url, style: "color:#{PRIMARY};text-decoration:underline;word-break:break-all;"),
            style: "margin:0;#{SMALL}")
    ])
  end

  private

  def email_table(width: nil, style: nil, &block)
    tag.table(role: "presentation", width: width, cellpadding: 0, cellspacing: 0, border: 0, style: style, &block)
  end
end
