#Requires -Module Pester

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\ProviderLinks.ps1')

    $script:VendorHosts = @{
        claude = @('claude.ai', 'anthropic.com')
        codex  = @('chatgpt.com', 'openai.com')
        cursor = @('cursor.com')
        grok   = @('x.ai', 'grok.com')
    }
}

Describe 'Get-ProviderLinkCatalog' {
    It 'ships usage and install/docs HTTPS URLs on each vendor domain' {
        $catalog = Get-ProviderLinkCatalog
        @($catalog.Keys) | Should -Be @('claude', 'codex', 'cursor', 'grok')

        foreach ($id in @('claude', 'codex', 'cursor', 'grok')) {
            $entry = $catalog[$id]
            $entry.Id | Should -Be $id
            $entry.Label | Should -Not -BeNullOrEmpty
            $entry.Usage.Kind | Should -Be 'Usage'
            $entry.Docs.Kind | Should -Be 'Docs'
            $entry.Usage.Label | Should -Not -BeNullOrEmpty
            $entry.Docs.Label | Should -Not -BeNullOrEmpty
            foreach ($url in @($entry.Usage.Url, $entry.Docs.Url)) {
                $url | Should -Match '^https://'
                $uri = [uri]$url
                $uri.Scheme | Should -Be 'https'
                $hosts = $script:VendorHosts[$id]
                $ok = $false
                foreach ($hostName in $hosts) {
                    if ($uri.Host -eq $hostName -or $uri.Host.EndsWith(".$hostName")) {
                        $ok = $true
                        break
                    }
                }
                $ok | Should -BeTrue -Because "$url must land on $($hosts -join ' / ')"
            }
        }
    }

    It 'resolves the same catalog URLs through Get-ProviderLinkUrl' {
        $catalog = Get-ProviderLinkCatalog
        foreach ($id in @('claude', 'codex', 'cursor', 'grok')) {
            (Get-ProviderLinkUrl -Provider $id -Kind Usage) | Should -Be $catalog[$id].Usage.Url
            (Get-ProviderLinkUrl -Provider $id -Kind Docs) | Should -Be $catalog[$id].Docs.Url
        }
    }
}

Describe 'Get-ProviderLinkMenuShape' {
    It 'uses one Usage-plus-Docs shape for all four platforms' {
        $items = @(Get-ProviderLinkMenuShape)
        $items.Count | Should -Be 8
        $byProvider = $items | Group-Object ProviderId
        @($byProvider | ForEach-Object { $_.Name }) | Should -Be @('claude', 'codex', 'cursor', 'grok')
        foreach ($group in $byProvider) {
            @($group.Group.Kind) | Should -Be @('Usage', 'Docs')
            $group.Group | ForEach-Object {
                $_.Url | Should -Match '^https://'
                $_.Label | Should -Not -BeNullOrEmpty
                $_.ProviderLabel | Should -Not -BeNullOrEmpty
            }
        }
    }
}
