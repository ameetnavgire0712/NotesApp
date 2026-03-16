import { User, Mail, Shield } from "lucide-react";

export default function ProfilePage() {
  return (
    <div className="flex flex-col h-screen">
      <header className="border-b border-border px-8 py-4 bg-card/80 backdrop-blur-sm">
        <h1 className="font-display text-2xl font-semibold text-foreground">Profile</h1>
        <p className="text-sm text-muted-foreground mt-1">Manage your account settings</p>
      </header>

      <div className="flex-1 overflow-y-auto px-8 py-8">
        <div className="max-w-lg">
          {/* Avatar */}
          <div className="flex items-center gap-4 mb-8">
            <div className="w-16 h-16 rounded-2xl bg-primary flex items-center justify-center">
              <User className="w-7 h-7 text-primary-foreground" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-foreground">User</h2>
              <p className="text-sm text-muted-foreground">Free Plan</p>
            </div>
          </div>

          {/* Info cards */}
          <div className="space-y-4">
            <div className="bg-card border border-border rounded-xl p-5">
              <div className="flex items-center gap-3 mb-3">
                <Mail className="w-4 h-4 text-accent" />
                <span className="text-sm font-medium text-foreground">Email</span>
              </div>
              <p className="text-sm text-muted-foreground">user@example.com</p>
            </div>

            <div className="bg-card border border-border rounded-xl p-5">
              <div className="flex items-center gap-3 mb-3">
                <Shield className="w-4 h-4 text-accent" />
                <span className="text-sm font-medium text-foreground">Account</span>
              </div>
              <p className="text-sm text-muted-foreground">Connect your account to manage settings</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
