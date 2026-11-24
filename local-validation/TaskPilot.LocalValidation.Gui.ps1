#requires -Version 5.1
function Set-TPGuiTestModeVisuals {
    param([Parameter(Mandatory=$true)]$Form)
    $context=Get-TPRuntimeContext
    if(-not$context.IsLocalValidation-or-not$context.IsTestMode-or$context.IsAcceptance){throw 'TP-LOCAL-GUI-CONTEXT'}
    $null=Get-TPGuiSandbox
    $Form.Text='[LOCAL VALIDATION ONLY] '+$Form.Text
    $strip=New-Object System.Windows.Forms.StatusStrip
    $strip.Name='TaskPilotLocalValidationStatus';$strip.Dock=[System.Windows.Forms.DockStyle]::Bottom
    $strip.BackColor=[Drawing.Color]::DarkMagenta;$strip.ForeColor=[Drawing.Color]::White
    $strip.SizingGrip=$false
    $label=New-Object System.Windows.Forms.ToolStripStatusLabel
    $label.Name='TaskPilotLocalValidationLabel'
    $label.Text='ローカル開発検証専用：合成データのみ・販売／一般配布禁止・通常版へ切替不可'
    $label.AutoToolTip=$false;$label.Spring=$true;$label.TextAlign=[Drawing.ContentAlignment]::MiddleLeft
    $null=$strip.Items.Add($label);$Form.Controls.Add($strip);$strip.BringToFront()
    $Form.AccessibleDescription='開発者本人が管理するクリーンな検証環境専用です。実データを読み込まず、通常版・独立モード・受入版へ切り替えません。'
}
