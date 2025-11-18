# Supabase Database Setup (LMS)

This folder contains SQL scripts to create and secure the database schema for the LMS.

Contents:
- supabase_schema.sql — Creates enums, tables, triggers, and Row Level Security (RLS) policies
- seed.sql — Minimal demo data to quickly test the app

## Prerequisites
- A Supabase project
- Access to the SQL Editor
- Service role key for backend use only (never expose in frontend)

## 1) Apply the schema
1. Open Supabase Dashboard > SQL
2. Paste and run the full contents of `supabase_schema.sql`
3. Verify:
   - Tables are created
   - Triggers: `on_auth_user_created` exists on `auth.users`
   - RLS is enabled on all public tables

The `handle_new_user` trigger automatically creates a `profiles` row when a new auth user signs up. It maps `raw_user_meta_data.role` (if present) to `profiles.role` with safe fallback to `student`.

User metadata example on sign-up:
```json
{
  "role": "teacher",
  "full_name": "Ada Lovelace",
  "avatar_url": "https://example.com/ada.png"
}
```

## 2) Enable Realtime
Realtime is used for:
- `chat_messages`
- `announcements`

Steps:
1. Supabase Dashboard > Realtime
2. Enable Realtime for tables `chat_messages` and `announcements`
3. Choose events: INSERT (and UPDATE if needed)
4. Save

Clients can then subscribe to these tables by course_id filters.

## 3) Create Storage Buckets
We use two buckets:

1. `submissions` (private)
   - Student submissions (files)
   - Make the bucket private
   - Access via signed URLs from backend or via RLS-protected edge functions

2. `course-assets` (public or restricted)
   - Course public media (images, PDFs)
   - Typically public; you can restrict with policies if needed

In Supabase Dashboard > Storage:
- Create `submissions` (private)
- Create `course-assets` (public)
- Optional: add storage policies for fine-grained control (outside the scope of this script)

Note: The `submissions.storage_path` field stores an object path (e.g., `assignmentId/userId/filename.pdf`).

## 4) Seed minimal data (optional)
After applying the schema:

1. Open SQL Editor again
2. Replace placeholder UUIDs in `seed.sql` with real `profiles.id` values for a teacher and a student
   - You can promote an existing user via:
     ```sql
     update public.profiles set role='teacher' where id = '<teacher-uuid>';
     ```
3. Run `seed.sql`

This will:
- Create a demo course and module
- Enroll the teacher and student
- Create a sample assignment and quiz
- Add a welcome announcement and a chat message

## 5) Auth configuration
- Default email/password auth is fine
- The `handle_new_user` trigger creates a profile row automatically
- If you want to force specific roles, include `role` in user metadata during sign-up; otherwise `student` is used

## 6) Security notes
- RLS policies restrict data access by role and enrollment:
  - Admins: full access
  - Teachers: manage their courses, content, and see submissions for their courses
  - Students: read course content of their enrollments and insert/update their own submissions/attempts
- Never expose the Supabase `service_role` key in the frontend. It must only be used on trusted backend servers.

## 7) Troubleshooting
- If you don’t see a profile for a new user, verify the `on_auth_user_created` trigger exists on `auth.users` and the function `public.handle_new_user` executes without error.
- If subscriptions don’t receive updates, confirm Realtime is enabled for the specific tables and your client filter matches.
