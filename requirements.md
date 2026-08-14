# Project Requirements Specification
**Project Name:** Smart QR & Geofencing Attendance Management System

## 1. System Overview
The Smart Attendance Management System is a modern, web-based B2B SaaS platform designed for educational institutions. It replaces manual roll-calling with a secure, highly scalable, and proxy-proof digital attendance system. The system utilizes rotating QR codes, GPS geofencing, and device fingerprinting to ensure that students are physically present in the classroom when marking their attendance. 

The application serves as a microservice that can operate independently or synchronize data directly with a college's legacy ERP system.

## 2. Functional Requirements
### 2.1 Attendance Validation Engine
- **Dynamic QR Generation:** The faculty dashboard must generate a QR code that rotates/refreshes every 10 seconds to prevent students from sharing screenshots of the code.
- **Geofencing:** The student's mobile device must report GPS coordinates during the scan. The system must calculate the Haversine distance between the student's location and the classroom's coordinates, enforcing a maximum radius (e.g., 50 meters).
- **Device Fingerprinting:** The system must restrict each physical mobile device to marking attendance for only one student account per session to prevent students from carrying their friends' phones.

### 2.2 Hierarchical User Management (RBAC)
The system must enforce strict Row Level Security (RLS) across a 6-tier hierarchy:
- **Super Admin:** Can manage global colleges, billing, and system-wide settings.
- **Principal:** Has a global view of all departments, HODs, faculty, and students within their specific college.
- **HOD (Head of Department):** Can manage and view analytics for all Faculty and Class Teachers within their department.
- **Class Teacher:** Can view and manage the students enrolled in their assigned classes.
- **Faculty:** Can generate QR sessions for the subjects they teach and view attendance logs for those specific sessions.
- **Student:** Can only view their own attendance analytics and use the QR scanner to mark themselves present.

### 2.3 Dashboard & Analytics
- **Live Feed:** Administrators must have access to a real-time dashboard showing live scans and active sessions across the campus.
- **Defaulter Reports:** The system must automatically identify and highlight students falling below the minimum required attendance threshold (e.g., 75%).

### 2.4 ERP Integration
- **Webhooks:** The system must support POST webhooks to immediately push finalized attendance records to external college ERP servers when a session ends.
- **API Access:** Must expose RESTful endpoints for third-party systems to fetch daily attendance CSV/JSON exports.

## 3. Non-Functional Requirements
- **Security:** All API endpoints must be protected by JWT (JSON Web Tokens). Database queries must be secured via Postgres Row Level Security (RLS) to prevent cross-tenant data leaks.
- **Scalability:** The architecture must handle sudden spikes in traffic (e.g., 100 students scanning a QR code simultaneously at the start of a lecture) without bottlenecking.
- **Availability:** The system must maintain 99.9% uptime to ensure no lecture is delayed due to software downtime.
- **User Experience (UX):** The interface must be responsive (mobile-first for students, desktop-optimized for admins) with a modern, glassmorphism design system to feel premium.

## 4. Technical Stack
- **Frontend Framework:** React 18 with Vite
- **Styling:** Tailwind CSS + Shadcn UI (for accessible, premium components)
- **Routing:** React Router DOM (v6)
- **State Management:** TanStack React Query (for caching and asynchronous state)
- **Backend & Database:** Supabase (PostgreSQL)
- **Authentication:** Supabase Auth (Email/Password with secure trigger-based onboarding)
- **Mapping/Geofencing:** Browser Geolocation API + SQL Haversine Distance calculations
- **QR Generation:** `qrcode.react` (Frontend) + `html5-qrcode` (Scanner)

## 5. Deployment & Business Model
- **Deployment:** Vercel (Frontend) & Supabase Cloud (Backend). 
- **Monetization (B2B SaaS):**
  - **Tier 1 (Basic):** Free up to 100 students.
  - **Tier 2 (Pro):** Per-student yearly subscription unlocking Geofencing and API access.
  - **Tier 3 (Enterprise):** White-labeled on-premise deployment for strict data compliance.
