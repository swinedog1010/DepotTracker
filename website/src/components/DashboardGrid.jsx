export default function DashboardGrid({ children }) {
  return (
    <section className="px-6 pb-16 max-w-[1280px] mx-auto">
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {children}
      </div>
    </section>
  );
}
