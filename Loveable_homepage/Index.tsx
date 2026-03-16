import { motion } from "framer-motion";
import { FileText, Sparkles, Zap, Shield } from "lucide-react";
import DocleeLogo from "@/components/DocleeLogo";
import { Button } from "@/components/ui/button";

const features = [
  {
    icon: FileText,
    title: "Capture Anything",
    description: "Upload files, take screenshots, jot quick notes, or save entire webpages — all in one place.",
  },
  {
    icon: Sparkles,
    title: "Ask in Plain English",
    description: "Find anything you've saved by describing it naturally to the infoSnap.ai chatbot. No folders, no tags needed.",
  },
  {
    icon: Zap,
    title: "Google Search Companion",
    description: "infoSnap.ai runs quietly in the background and surfaces your saved docs right inside Google results when they're relevant.",
  },
  {
    icon: Shield,
    title: "Private & Secure",
    description: "Your data stays yours. Bank-level encryption ensures everything you store is protected end-to-end.",
  },
];

const fadeUp = {
  hidden: { opacity: 0, y: 24 },
  visible: (i: number) => ({
    opacity: 1,
    y: 0,
    transition: { delay: i * 0.1, duration: 0.6, ease: [0.25, 0.46, 0.45, 0.94] as const },
  }),
};

const Index = () => {
  return (
    <div className="min-h-screen bg-background overflow-hidden">
      {/* Nav */}
      <nav className="fixed top-0 w-full z-50 glass">
        <div className="container mx-auto flex items-center justify-between py-4 px-6">
          <DocleeLogo size="small" />
          <div className="flex items-center gap-6">
            <a href="#features" className="text-sm text-muted-foreground hover:text-foreground transition-colors">
              Features
            </a>
            <Button size="sm">Get Started</Button>
          </div>
        </div>
      </nav>

      {/* Hero */}
      <section className="relative pt-32 pb-24 px-6">
        {/* Background glow */}
        <div className="absolute top-1/4 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[400px] rounded-full bg-primary/5 blur-[120px] pointer-events-none" />

        <div className="container mx-auto max-w-4xl text-center relative z-10">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7 }}
          >
            <DocleeLogo size="large" />
          </motion.div>

          <motion.h1
            className="mt-12 text-5xl md:text-7xl font-display font-bold leading-[1.08] tracking-tight"
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.15, duration: 0.7 }}
          >
            Save anything,{" "}
            <span className="text-gradient">find it instantly.</span>
          </motion.h1>

          <motion.p
            className="mt-6 text-lg md:text-xl text-muted-foreground max-w-2xl mx-auto leading-relaxed"
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.3, duration: 0.7 }}
          >
            Capture files, screenshots, notes, and webpages — then let AI retrieve
            them instantly through natural conversation or right inside your Google searches.
          </motion.p>

          <motion.div
            className="mt-10 flex flex-col sm:flex-row items-center justify-center gap-4"
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.45, duration: 0.7 }}
          >
            <Button size="lg" className="px-8 text-base font-medium shadow-lg shadow-primary/20">
              Start Free Trial
            </Button>
            <Button variant="outline" size="lg" className="px-8 text-base font-medium">
              Watch Demo
            </Button>
          </motion.div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="py-24 px-6">
        <div className="container mx-auto max-w-5xl">
          <motion.div
            className="text-center mb-16"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: "-100px" }}
            variants={fadeUp}
            custom={0}
          >
            <h2 className="text-3xl md:text-4xl font-display font-bold tracking-tight">
              Capture, store, retrieve — effortlessly
            </h2>
            <p className="mt-4 text-muted-foreground text-lg max-w-xl mx-auto">
              Everything you save becomes searchable and always within reach.
            </p>
          </motion.div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {features.map((feature, i) => (
              <motion.div
                key={feature.title}
                className="group relative rounded-xl border border-border bg-card/50 p-8 hover:border-primary/30 transition-all duration-300"
                style={{ boxShadow: "var(--shadow-card)" }}
                initial="hidden"
                whileInView="visible"
                viewport={{ once: true, margin: "-60px" }}
                variants={fadeUp}
                custom={i + 1}
              >
                <div className="mb-4 inline-flex items-center justify-center w-11 h-11 rounded-lg bg-primary/10 text-primary">
                  <feature.icon size={22} />
                </div>
                <h3 className="text-lg font-display font-semibold mb-2">
                  {feature.title}
                </h3>
                <p className="text-muted-foreground leading-relaxed text-sm">
                  {feature.description}
                </p>
              </motion.div>
            ))}
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="py-24 px-6">
        <div className="container mx-auto max-w-3xl text-center">
          <motion.div
            className="rounded-2xl border border-border bg-card/40 p-12 md:p-16 glow-border"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={fadeUp}
            custom={0}
          >
            <h2 className="text-3xl md:text-4xl font-display font-bold tracking-tight">
              Ready to get started?
            </h2>
            <p className="mt-4 text-muted-foreground text-lg">
              Join thousands of teams already using infoSnap.ai
            </p>
            <Button size="lg" className="mt-8 px-10 text-base font-medium shadow-lg shadow-primary/20">
              Try infoSnap.ai Free
            </Button>
          </motion.div>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-border py-10 px-6">
        <div className="container mx-auto flex flex-col md:flex-row items-center justify-between gap-4">
          <DocleeLogo size="small" />
          <p className="text-sm text-muted-foreground">
            © 2026 infoSnap.ai — All rights reserved.
          </p>
        </div>
      </footer>
    </div>
  );
};

export default Index;
