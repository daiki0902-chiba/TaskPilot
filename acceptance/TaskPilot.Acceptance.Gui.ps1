#requires -Version 5.1
# Loaded only by the signed dedicated acceptance entry after package validation.
function Set-TPGuiTestModeVisuals {
    param([Parameter(Mandatory=$true)]$Form)
    $context=Get-TPRuntimeContext
    if(-not$context.IsAcceptance-or-not$context.IsTestMode){throw 'TP-ACCEPTANCE-GUI-CONTEXT'}
    $null=Get-TPGuiSandbox
    $Form.Text='[ACCEPTANCE ONLY] [TEST MODE] '+$Form.Text
    $strip=New-Object System.Windows.Forms.StatusStrip
    $strip.Name='TaskPilotAcceptanceStatus';$strip.Dock=[System.Windows.Forms.DockStyle]::Bottom
    $strip.BackColor=[Drawing.Color]::DarkBlue;$strip.ForeColor=[Drawing.Color]::White
    $strip.SizingGrip=$false
    $label=New-Object System.Windows.Forms.ToolStripStatusLabel
    $label.Name='TaskPilotAcceptanceLabel'
    $label.Text='受入専用テスト環境：合成データのみ使用（通常版へ切替不可）'
    $label.AutoToolTip=$false;$label.Spring=$true;$label.TextAlign=[Drawing.ContentAlignment]::MiddleLeft
    $null=$strip.Items.Add($label);$Form.Controls.Add($strip);$strip.BringToFront()
    $Form.AccessibleDescription='受入専用の合成データ環境です。通常版のデータを読み込んだり通常版へ切り替えたりする機能はありません。'
}
