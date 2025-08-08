function Get-GatewayAPIDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TraefikNamespace = "traefik",
        
        [Parameter(Mandatory)]
        [string]$AppNamespace,
        
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter(Mandatory)]
        [string]$TestHostname,
        
        [Parameter()]
        [switch]$IncludeTraefikInternals,
        
        [Parameter()]
        [switch]$IncludePodLogs
    )
    
    $diagnostics = [PSCustomObject]@{
        Timestamp = Get-Date
        LoadBalancer = $null
        GatewayClass = $null
        Gateways = @()
        HTTPRoutes = @()
        Services = @()
        Endpoints = @()
        TraefikConfig = $null
        TraefikInternals = $null
        DNSResolution = $null
        CertificateStatus = $null
        Events = @()
        PodStatus = @()
        Logs = $null
    }
    
    Write-Verbose "Starting Gateway API diagnostics..."
    
    # 1. LoadBalancer Status
    Write-Verbose "Checking LoadBalancer service..."
    $lbService = kubectl get svc -n $TraefikNamespace -o json | 
        ConvertFrom-Json | 
        Select-Object -ExpandProperty items |
        Where-Object { $_.spec.type -eq "LoadBalancer" } |
        Select-Object -First 1
    
    if ($lbService) {
        $diagnostics.LoadBalancer = [PSCustomObject]@{
            Name = $lbService.metadata.name
            Namespace = $lbService.metadata.namespace
            ExternalIP = $lbService.status.loadBalancer.ingress[0].ip
            Ports = $lbService.spec.ports | ForEach-Object {
                [PSCustomObject]@{
                    Name = $_.name
                    Port = $_.port
                    TargetPort = $_.targetPort
                    NodePort = $_.nodePort
                }
            }
            Endpoints = (kubectl get endpoints -n $TraefikNamespace $lbService.metadata.name -o json | 
                ConvertFrom-Json).subsets.addresses.ip -join ", "
        }
    }
    
    # 2. GatewayClass
    Write-Verbose "Checking GatewayClass..."
    $gatewayClasses = kubectl get gatewayclass -o json | ConvertFrom-Json
    if ($gatewayClasses.items) {
        $diagnostics.GatewayClass = $gatewayClasses.items | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.metadata.name
                Controller = $_.spec.controllerName
                Accepted = ($_.status.conditions | Where-Object { $_.type -eq "Accepted" }).status
                Message = ($_.status.conditions | Where-Object { $_.type -eq "Accepted" }).message
            }
        }
    }
    
    # 3. Gateways (check all namespaces)
    Write-Verbose "Checking Gateways..."
    $gateways = kubectl get gateway -A -o json | ConvertFrom-Json
    if ($gateways.items) {
        $diagnostics.Gateways = $gateways.items | ForEach-Object {
            $gateway = $_
            [PSCustomObject]@{
                Name = $gateway.metadata.name
                Namespace = $gateway.metadata.namespace
                ClassName = $gateway.spec.gatewayClassName
                Addresses = ($gateway.status.addresses.value -join ", ")
                Listeners = $gateway.spec.listeners | ForEach-Object {
                    [PSCustomObject]@{
                        Name = $_.name
                        Port = $_.port
                        Protocol = $_.protocol
                        Hostname = $_.hostname
                        AllowedNamespaces = $_.allowedRoutes.namespaces.from
                    }
                }
                Conditions = $gateway.status.conditions | ForEach-Object {
                    [PSCustomObject]@{
                        Type = $_.type
                        Status = $_.status
                        Reason = $_.reason
                        Message = $_.message
                    }
                }
                AttachedRoutes = ($gateway.status.listeners.attachedRoutes | Measure-Object -Sum).Sum
            }
        }
    }
    
    # 4. HTTPRoutes
    Write-Verbose "Checking HTTPRoutes..."
    $httproutes = kubectl get httproute -A -o json | ConvertFrom-Json
    if ($httproutes.items) {
        $diagnostics.HTTPRoutes = $httproutes.items | ForEach-Object {
            $route = $_
            [PSCustomObject]@{
                Name = $route.metadata.name
                Namespace = $route.metadata.namespace
                Hostnames = $route.spec.hostnames -join ", "
                ParentRefs = $route.spec.parentRefs | ForEach-Object {
                    "$($_.namespace)/$($_.name)"
                } | Join-String -Separator ", "
                Rules = $route.spec.rules.Count
                BackendRefs = $route.spec.rules.backendRefs | ForEach-Object {
                    $_.name
                } | Select-Object -Unique | Join-String -Separator ", "
                Status = $route.status.parents | ForEach-Object {
                    $parent = $_
                    [PSCustomObject]@{
                        ParentRef = "$($parent.parentRef.namespace)/$($parent.parentRef.name)"
                        Accepted = ($parent.conditions | Where-Object { $_.type -eq "Accepted" }).status
                        Reason = ($parent.conditions | Where-Object { $_.type -eq "Accepted" }).reason
                        ResolvedRefs = ($parent.conditions | Where-Object { $_.type -eq "ResolvedRefs" }).status
                    }
                }
            }
        }
    }
    
    # 5. Services and Endpoints
    Write-Verbose "Checking Services and Endpoints..."
    $services = kubectl get svc -n $AppNamespace -o json | ConvertFrom-Json
    if ($services.items) {
        $diagnostics.Services = $services.items | ForEach-Object {
            $svc = $_
            $endpoints = kubectl get endpoints -n $AppNamespace $svc.metadata.name -o json 2>$null | ConvertFrom-Json
            
            [PSCustomObject]@{
                Name = $svc.metadata.name
                Namespace = $svc.metadata.namespace
                Type = $svc.spec.type
                ClusterIP = $svc.spec.clusterIP
                Ports = ($svc.spec.ports | ForEach-Object { "$($_.port):$($_.targetPort)" }) -join ", "
                Selector = ($svc.spec.selector.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
                Endpoints = if ($endpoints.subsets) {
                    ($endpoints.subsets.addresses.ip -join ", ")
                } else {
                    "No endpoints"
                }
            }
        }
    }
    
    # 6. Traefik Configuration
    Write-Verbose "Checking Traefik deployment configuration..."
    $traefikDeploy = kubectl get deployment -n $TraefikNamespace -o json | 
        ConvertFrom-Json | 
        Select-Object -ExpandProperty items |
        Where-Object { $_.metadata.name -like "*traefik*" } |
        Select-Object -First 1
    
    if ($traefikDeploy) {
        $container = $traefikDeploy.spec.template.spec.containers | 
            Where-Object { $_.name -like "*traefik*" } | 
            Select-Object -First 1
        
        $diagnostics.TraefikConfig = [PSCustomObject]@{
            DeploymentName = $traefikDeploy.metadata.name
            Replicas = "$($traefikDeploy.status.readyReplicas)/$($traefikDeploy.spec.replicas)"
            Image = $container.image
            EntryPoints = $container.args | Where-Object { $_ -like "*entrypoint*" }
            Providers = $container.args | Where-Object { $_ -like "*provider*" }
        }
    }
    
    # 7. Traefik Internal API (if requested)
    if ($IncludeTraefikInternals) {
        Write-Verbose "Checking Traefik internal state..."
        try {
            $traefikPod = (kubectl get pods -n $TraefikNamespace -o json | 
                ConvertFrom-Json).items | 
                Where-Object { $_.metadata.name -like "*traefik*" -and $_.status.phase -eq "Running" } | 
                Select-Object -First 1
            
            if ($traefikPod) {
                $podName = $traefikPod.metadata.name
                
                $routers = kubectl exec -n $TraefikNamespace $podName -- curl -s http://localhost:8080/api/http/routers 2>$null | ConvertFrom-Json
                $services = kubectl exec -n $TraefikNamespace $podName -- curl -s http://localhost:8080/api/http/services 2>$null | ConvertFrom-Json
                $entrypoints = kubectl exec -n $TraefikNamespace $podName -- curl -s http://localhost:8080/api/entrypoints 2>$null | ConvertFrom-Json
                
                $diagnostics.TraefikInternals = [PSCustomObject]@{
                    Routers = $routers | ForEach-Object {
                        [PSCustomObject]@{
                            Name = $_.name
                            Rule = $_.rule
                            Service = $_.service
                            Status = $_.status
                        }
                    }
                    Services = $services | ForEach-Object {
                        [PSCustomObject]@{
                            Name = $_.name
                            Type = $_.type
                            Status = $_.status
                        }
                    }
                    EntryPoints = $entrypoints | ForEach-Object {
                        [PSCustomObject]@{
                            Name = $_.name
                            Address = $_.address
                        }
                    }
                }
            }
        } catch {
            Write-Warning "Could not fetch Traefik internals: $_"
        }
    }
    
    # 8. DNS Resolution
    Write-Verbose "Checking DNS resolution..."
    if ($TestHostname) {
        try {
            $dnsResult = Resolve-DnsName $TestHostname -ErrorAction SilentlyContinue
            $diagnostics.DNSResolution = [PSCustomObject]@{
                Hostname = $TestHostname
                ResolvedIP = ($dnsResult | Where-Object { $_.Type -eq "A" }).IPAddress
                ExpectedIP = $diagnostics.LoadBalancer.ExternalIP
                Match = ($dnsResult | Where-Object { $_.Type -eq "A" }).IPAddress -eq $diagnostics.LoadBalancer.ExternalIP
            }
        } catch {
            $diagnostics.DNSResolution = [PSCustomObject]@{
                Hostname = $TestHostname
                Error = $_.Exception.Message
            }
        }
    }
    
    # 9. Certificate Status
    Write-Verbose "Checking certificates..."
    $certificates = kubectl get certificate -n $AppNamespace -o json 2>$null | ConvertFrom-Json
    if ($certificates.items) {
        $diagnostics.CertificateStatus = $certificates.items | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.metadata.name
                Ready = ($_.status.conditions | Where-Object { $_.type -eq "Ready" }).status
                SecretName = $_.spec.secretName
                DNSNames = $_.spec.dnsNames -join ", "
                Issuer = $_.spec.issuerRef.name
            }
        }
    }
    
    # 10. Pod Status
    Write-Verbose "Checking pod status..."
    $allPods = @()
    $allPods += kubectl get pods -n $TraefikNamespace -o json | ConvertFrom-Json | Select-Object -ExpandProperty items
    $allPods += kubectl get pods -n $AppNamespace -o json | ConvertFrom-Json | Select-Object -ExpandProperty items
    
    $diagnostics.PodStatus = $allPods | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.metadata.name
            Namespace = $_.metadata.namespace
            Status = $_.status.phase
            Ready = "$($_.status.containerStatuses.Where({$_.ready}).Count)/$($_.status.containerStatuses.Count)"
            Restarts = ($_.status.containerStatuses.restartCount | Measure-Object -Sum).Sum
            Age = if ($_.metadata.creationTimestamp) {
                $created = [DateTime]$_.metadata.creationTimestamp
                $age = (Get-Date) - $created
                if ($age.TotalDays -gt 1) { "{0:N0}d" -f $age.TotalDays }
                elseif ($age.TotalHours -gt 1) { "{0:N0}h" -f $age.TotalHours }
                else { "{0:N0}m" -f $age.TotalMinutes }
            }
        }
    }
    
    # 11. Recent Events
    Write-Verbose "Checking recent events..."
    $events = @()
    $events += kubectl get events -n $TraefikNamespace --sort-by='.lastTimestamp' -o json | 
        ConvertFrom-Json | 
        Select-Object -ExpandProperty items |
        Select-Object -Last 5
    $events += kubectl get events -n $AppNamespace --sort-by='.lastTimestamp' -o json | 
        ConvertFrom-Json | 
        Select-Object -ExpandProperty items |
        Select-Object -Last 5
    
    if ($events) {
        $diagnostics.Events = $events | ForEach-Object {
            [PSCustomObject]@{
                Namespace = $_.metadata.namespace
                Type = $_.type
                Reason = $_.reason
                Object = "$($_.involvedObject.kind)/$($_.involvedObject.name)"
                Message = $_.message
                Time = $_.lastTimestamp
            }
        }
    }
    
    # 12. Pod Logs (if requested)
    if ($IncludePodLogs) {
        Write-Verbose "Collecting pod logs..."
        $logs = @{}
        
        # Traefik logs
        $traefikPod = (kubectl get pods -n $TraefikNamespace -o json | 
            ConvertFrom-Json).items | 
            Where-Object { $_.metadata.name -like "*traefik*" } | 
            Select-Object -First 1
        
        if ($traefikPod) {
            $logs["Traefik"] = kubectl logs -n $TraefikNamespace $traefikPod.metadata.name --tail=20
        }
        
        # App logs
        $appPod = (kubectl get pods -n $AppNamespace -l app=$ServiceName -o json | 
            ConvertFrom-Json).items | 
            Select-Object -First 1
        
        if ($appPod) {
            $logs["Application"] = kubectl logs -n $AppNamespace $appPod.metadata.name --tail=20
        }
        
        $diagnostics.Logs = $logs
    }
    
    return $diagnostics
}

# Helper function to display a summary
function Show-GatewayAPISummary {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [PSCustomObject]$Diagnostics
    )
    
    Write-Host "`n========== GATEWAY API DIAGNOSTICS SUMMARY ==========" -ForegroundColor Cyan
    Write-Host "Timestamp: $($Diagnostics.Timestamp)" -ForegroundColor Gray
    
    # LoadBalancer
    if ($Diagnostics.LoadBalancer) {
        Write-Host "`n[LoadBalancer]" -ForegroundColor Yellow
        Write-Host "  External IP: $($Diagnostics.LoadBalancer.ExternalIP)" -ForegroundColor Green
        Write-Host "  Ports: $(($Diagnostics.LoadBalancer.Ports | ForEach-Object { "$($_.Port):$($_.TargetPort)" }) -join ', ')"
    }
    
    # Gateways
    Write-Host "`n[Gateways]" -ForegroundColor Yellow
    foreach ($gw in $Diagnostics.Gateways) {
        $status = if (($gw.Conditions | Where-Object { $_.Type -eq "Accepted" }).Status -eq "True") { "✓" } else { "✗" }
        Write-Host "  $status $($gw.Namespace)/$($gw.Name) - Attached Routes: $($gw.AttachedRoutes)"
        foreach ($listener in $gw.Listeners) {
            Write-Host "    - $($listener.Name): $($listener.Protocol)/$($listener.Port)"
        }
    }
    
    # HTTPRoutes
    Write-Host "`n[HTTPRoutes]" -ForegroundColor Yellow
    foreach ($route in $Diagnostics.HTTPRoutes) {
        Write-Host "  $($route.Namespace)/$($route.Name)"
        Write-Host "    Hostnames: $($route.Hostnames)"
        foreach ($status in $route.Status) {
            $symbol = if ($status.Accepted -eq "True") { "✓" } else { "✗" }
            Write-Host "    $symbol Parent: $($status.ParentRef) - $($status.Reason)"
        }
    }
    
    # DNS
    if ($Diagnostics.DNSResolution) {
        Write-Host "`n[DNS Resolution]" -ForegroundColor Yellow
        if ($Diagnostics.DNSResolution.Match -eq $false) {
            Write-Host "  ✗ DNS MISMATCH!" -ForegroundColor Red
            Write-Host "    Expected: $($Diagnostics.DNSResolution.ExpectedIP)"
            Write-Host "    Actual: $($Diagnostics.DNSResolution.ResolvedIP)"
        } else {
            Write-Host "  ✓ DNS OK: $($Diagnostics.DNSResolution.Hostname) -> $($Diagnostics.DNSResolution.ResolvedIP)" -ForegroundColor Green
        }
    }
    
    # Services
    Write-Host "`n[Services]" -ForegroundColor Yellow
    foreach ($svc in $Diagnostics.Services) {
        $epStatus = if ($svc.Endpoints -ne "No endpoints") { "✓" } else { "✗" }
        Write-Host "  $epStatus $($svc.Namespace)/$($svc.Name) - Endpoints: $($svc.Endpoints)"
    }
    
    Write-Host "`n================================================" -ForegroundColor Cyan
}

# Export the functions
Export-ModuleMember -Function Get-GatewayAPIDiagnostics, Show-GatewayAPISummary