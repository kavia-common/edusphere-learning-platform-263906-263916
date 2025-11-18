-- Minimal demo data for LMS
-- Run in Supabase SQL Editor AFTER applying supabase_schema.sql
-- Replace UUIDs with real user IDs from your auth.users if you want specific teachers/students.

-- Example placeholders: you can query your profiles to find actual UUIDs.
-- select id, role, full_name from public.profiles;

-- For demo, we create a teacher and student by promoting existing users manually if needed:
-- update public.profiles set role='teacher' where id = '00000000-0000-0000-0000-000000000001';
-- update public.profiles set role='student' where id = '00000000-0000-0000-0000-000000000002';

-- Variables (replace with real UUIDs from profiles)
-- \set teacher '00000000-0000-0000-0000-000000000001'
-- \set student '00000000-0000-0000-0000-000000000002'

-- Create course
insert into public.courses (id, title, description, teacher_id)
values (gen_random_uuid(), 'Intro to Web Development', 'Learn HTML, CSS, and JS basics', :'teacher')
returning id into course_id;

-- Enroll teacher and student
insert into public.enrollments (user_id, course_id, role) values (:'teacher', course_id, 'teacher');
insert into public.enrollments (user_id, course_id, role) values (:'student', course_id, 'student');

-- Create a module
insert into public.modules (id, course_id, title, description, position)
values (gen_random_uuid(), course_id, 'Getting Started', 'Course overview and setup', 1)
returning id into module_id;

-- Create an assignment
insert into public.assignments (id, course_id, module_id, title, description, due_at, max_points, type)
values (gen_random_uuid(), course_id, module_id, 'Install Tooling', 'Install Node.js and VS Code', now() + interval '7 days', 10, 'text')
returning id into assignment_id;

-- Optional: Create a quiz linked to the assignment
insert into public.quizzes (id, course_id, assignment_id, time_limit_minutes)
values (gen_random_uuid(), course_id, assignment_id, 15)
returning id into quiz_id;

-- Quiz questions
insert into public.quiz_questions (quiz_id, question_text, options, correct_answer, points, position)
values
(quiz_id, 'What does HTML stand for?', '["HyperText Markup Language","Home Tool Markup Language","Hyperlinks and Text Markup Language"]', '"HyperText Markup Language"', 1, 1),
(quiz_id, 'Which tag is used for the largest heading?', '["<h6>","<h1>","<head>"]', '"<h1>"', 1, 2);

-- Sample announcement
insert into public.announcements (course_id, teacher_id, title, body)
values (course_id, :'teacher', 'Welcome!', 'Welcome to the course. Check the first module.');

-- Sample chat message
insert into public.chat_messages (course_id, user_id, message)
values (course_id, :'student', 'Excited to learn!');
